%w(rubygems active_support).each { |f| require f }

module Workflow

  @@specifications = {}

  class << self

    def specify(name = :default, meta = {:meta => {}}, &specification)
      if @@specifications[name]
        @@specifications[name].blat(meta[:meta], &specification)
      else
        @@specifications[name] = Specification.new(meta[:meta], &specification)
      end
    end

    def reset!
      @@specifications = {}
    end

  private

    def find_spec_for(klass) # it could either be a symbol, or a class, man, urgh.
      target = klass 
      while @@specifications[target].nil? and target != Object
        target = target.superclass
      end
      puts target
      @@specifications[target]
    end

  public
    def new(name = :default, args = {})
      find_spec_for(name).to_instance(args[:reconstitute_at])
    end

    def reconstitute(reconstitute_at = nil, name = :default)
      find_spec_for(name).to_instance(reconstitute_at)
    end

    # this method should be split up into Workflow::Integrator
    # utility sub-classes, with an ActiveRecordIntegrator and a
    # ClassIntegrator... that both respond to integrate! :)
    def append_features(receiver)
      # add a meta method
      receiver.instance_eval do
        def workflow(&specification)
          Workflow.specify(self, &specification)
        end
        # returns all the states specified in the main workflow on the specifying class
        def states
          @@specifications[self].states.map(&:name)
        end
      end
      # this should check the inheritance tree, as subclassed models
      # won't return ActiveRecord::Base, they'll return something else
      # despite being inherited from AR::Base...
      if receiver.superclass.to_s == 'ActiveRecord::Base'
        # active record gets this style of integration
        receiver.class_eval do
          alias_method :initialize_before_workflow, :initialize
          attr_accessor :workflow

          def initialize(attributes = nil)
            initialize_before_workflow(attributes)
            @workflow = Workflow.new(self.class)
            @workflow.bind_to(self)
          end
          def after_find
            @workflow = if workflow_state.nil?
              Workflow.new(self.class)
            else
              Workflow.reconstitute(workflow_state.to_sym, self.class)
            end
            @workflow.bind_to(self)
          end
          # this aliasing doesn't get called work when a before_save method exists on the model
          # perhaps the model clobbers the workflow method?
          # TODO fix this, perhaps with active support style chaining?
          alias_method :before_save_before_workflow, :before_save
          def before_save
            before_save_before_workflow
            self.workflow_state = @workflow.state.to_s
          end
          # skips all the hooks, and delegates an update call to the workflow object
          def override_state_with(name)
            @workflow.override_state_with(name)
            @workflow.current_state.name
          end
        end
      else
        # anything else gets this style of integration
        receiver.class_eval do
          alias_method :initialize_before_workflow, :initialize
          attr_reader :workflow
          def initialize(*args, &block)
            initialize_before_workflow(*args, &block)
            @workflow = Workflow.new(self.class)
            @workflow.bind_to(self)
          end
        end
      end
    end

  end

  class Specification

    attr_accessor :states, :meta, :on_transition

    def initialize(meta = {}, &specification)
      @states = []
      @meta = meta
      instance_eval(&specification)
    end

    def to_instance(reconstitute_at = nil)
      Instance.new(states, @on_transition, @meta, reconstitute_at)
    end

    def blat(meta = {}, &specification)
      instance_eval(&specification)
    end

  private

    def state(name, meta = {:meta => {}}, &events_and_etc)
      # meta[:meta] to keep the API consistent..., gah
      self.states << State.new(name, meta[:meta])
      instance_eval(&events_and_etc) if events_and_etc
    end

    def on_transition(&proc)
      @on_transition = proc
    end

    def event(name, args = {}, &action)
      scoped_state.add_event Event.new(name, args[:transitions_to], (args[:meta] or {}), &action)
    end

    def on_entry(&proc)
      scoped_state.on_entry = proc
    end

    def on_exit(&proc)
      scoped_state.on_exit = proc
    end

    def scoped_state
      states.last
    end

  end

  class Instance

    class TransitionHalted < Exception

      attr_reader :halted_because

      def initialize(msg = nil)
        @halted_because = msg
        super msg
      end

    end

    attr_accessor :states, :meta, :current_state, :on_transition, :context

    def initialize(states, on_transition, meta = {}, reconstitute_at = nil)
      @states, @on_transition, @meta = states, on_transition, meta
      @context = self
      if reconstitute_at.nil?
        transition(nil, states.first, nil)
      else
        self.current_state = states(reconstitute_at)
      end
    end

    def state(fetch = nil)
      if fetch
        states(fetch)
      else
        current_state.name
      end
    end

    def states(name = nil)
      if name
        @states.detect { |s| s.name == name }
      else
        @states.collect { |s| s.name }
      end
    end

    # skips all the hooks, and just updates the state, providing it exists
    def override_state_with(name)
      found = states(name)
      self.current_state = found if found
      self.current_state.name
    end

    def method_missing(name, *args)
      if current_state.events(name)
        process_event!(name, *args)
      elsif name.to_s[-1].chr == '?' and states(name.to_s[0..-2].to_sym)
        current_state == states(name.to_s[0..-2].to_sym)
      else
        super
      end
    end

    def bind_to(another_context)
      self.context = another_context
      patch_context(another_context) if another_context != self
    end

    def halted?
      @halted
    end

    def halted_because
      @halted_because
    end

  private

    def patch_context(context)
      context.instance_variable_set("@workflow", self)

      context.instance_eval do
        alias :method_missing_before_workflow :method_missing
        def method_missing(method, *args)
          # we create an array of valid method names that can be delegated to the workflow,
          # otherwise methods are sent onwards down the chain.
          # this solves issues with catching a NoMethodError when it means something OTHER than a method missing in the workflow instance
          # for example, perhaps a NoMethodError is raised in an on_entry block or similar.
          if potential_methods.include?(method.to_sym)
            @workflow.send(method, *args)
          else
            method_missing_before_workflow(method, *args)
          end
        end

        # rails 2.2 is stricter about method_missing, now we need respond_to
        alias :respond_to_before_workflow :respond_to?
        def respond_to?(method, include_private=false)
          if potential_methods.include?(method.to_sym)
            return true
          else
            respond_to_before_workflow(method, include_private)
          end
        end

        # TODO "potential_methods" should probably be an instance variable on target context
        def potential_methods
          methods = [:states, :state, :current_state, :override_state_with, :halted?, :halted_because] +
                            (@workflow.states.collect {|s| "#{s}?".to_sym})
          states = @workflow.states(@workflow.state)
          methods += states.events unless states.is_a?(Array)
          return methods
        end
      end
    end

    def process_event!(name, *args)
      event = current_state.events(name)
      @halted_because = nil
      @halted = false
      @raise_exception_on_halt = false
      # i don't think we've tested that the return value is
      # what the action returns... so yeah, test it, at some point.
      return_value = run_action(event.action, *args)
      if @halted
        if @raise_exception_on_halt
          raise TransitionHalted.new(@halted_because)
        else
          false
        end
      else
        run_on_transition(current_state, states(event.transitions_to), name, *args)
        transition(current_state, states(event.transitions_to), name, *args)
        return_value
      end
    end

    def halt(reason = nil)
      @halted_because = reason
      @halted = true
      @raise_exception_on_halt = false
    end

    def halt!(reason = nil)
      @halted_because = reason
      @halted = true
      @raise_exception_on_halt = true
    end

    def transition(from, to, name, *args)
      run_on_exit(from, to, name, *args)
      self.current_state = to
      run_on_entry(to, from, name, *args)
    end

    def run_on_transition(from, to, event, *args)
      context.instance_exec(from.name, to.name, event, *args, &on_transition) if on_transition
    end

    def run_action(action, *args)
      context.instance_exec(*args, &action) if action
    end

    def run_on_entry(state, prior_state, triggering_event, *args)
      if state.on_entry
        context.instance_exec(prior_state.name, triggering_event, *args, &state.on_entry)
      end
    end

    def run_on_exit(state, new_state, triggering_event, *args)
      if state and state.on_exit
        context.instance_exec(new_state.name, triggering_event, *args, &state.on_exit)
      end
    end

  end

  class State

    attr_accessor :name, :events, :meta, :on_entry, :on_exit

    def initialize(name, meta = {})
      @name, @events, @meta = name, [], meta
    end

    def events(name = nil)
      if name
        @events.detect { |e| e.name == name }
      else
        @events.collect { |e| e.name }
      end
    end

    def add_event(event)
      @events << event
    end

  end

  class Event

    attr_accessor :name, :transitions_to, :meta, :action

    def initialize(name, transitions_to, meta = {}, &action)
      @name, @transitions_to, @meta, @action = name, transitions_to, meta, action
    end

  end
end

