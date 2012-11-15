require 'utilrb/thread_pool'


module Utilrb
    # Simple event loop which supports timers and defers blocking operations to
    # a thread pool those results are queued and being processed by the event
    # loop thread at the end of each step. 
    #
    # All events must be code blocks which will be executed at the end of each step.
    # There is no support for filtering or event propagations.
    #
    # For an easy integration of ruby classes into the event loop the {Forwardable#def_event_loop_delegator}
    # can be used.
    #
    # @example Example for using the EventLoop
    #   event_loop = EventLoop.new 
    #   event_loop.once do 
    #     puts "called once"
    #   end
    #
    #   event_loop.every(1.0) do 
    #     puts "called every second"
    #   end
    #
    #   callback = Proc.new |result|
    #     puts result 
    #   end
    #   event_loop.defer callback do
    #     sleep 2
    #     "result from the worker thread #{Thread.current}"
    #   end
    #
    #   event_loop.exec
    # 
    # @author Alexander Duda <Alexander.Duda@dfki.de>
    class EventLoop
        # Timer for the {EventLoop} which supports single shot and periodic activation
        #
        # @example
        #       loop = EventLoop.new
        #       timer = EventLoop.every(0.1) do 
        #                  puts 123
        #               end
        #       loop.exec
        class Timer
            attr_accessor :single_shot
            attr_accessor :period
            attr_accessor :event_loop
            attr_reader :result

            # A timer
            #
            # @param [EventLoop] event_loop the {EventLoop} the timer belongs to
            # @param[Float] period The period of the timer in seconds.
            # @param[Boolean] single_shot if true the timer will fire only once
            # @param[#call] block The code block which will be executed each time the timer fires
            # @see EventLoop#once
            def initialize(event_loop,period=nil,single_shot=false,&block)
                @block = block
                @event_loop = event_loop
                @last_call = Time.now
                @period = period
                @single_shot = single_shot
            end

            # Cancels the timer. If it is not running it will do nothing
            def cancel
                @event_loop.cancel_timer self
            end

            # Returns true if the timer is currently running.
            #
            # @return [boolean]
            def running?
                @event_loop.timer? self
            end

            # Starts the timer by adding itself to the EventLoop the timer
            # belongs to. If no period is given the one which was given during
            # initializing will be used.
            #
            # @param [Float] period The period in seconds
            # @raise [ArgumentError] if no period is specified
            # @return [Timer]
            def start(period = @period)
                @period = period
                raise ArgumentError,"no period is given" unless @period
                @event_loop << self
                self
            end

            # Returns true if the timer should fire now. This is called by the
            # EventLoop to check if the timer elapsed.
            #
            # @param [Time] time The time used for checking
            # @return [Boolean}
            def timeout?(time = Time.now)
                if(time-@last_call).to_f >= @period
                    true
                else
                    false
                end
            end

            # Returns true if the timer is a single shot timer.
            #
            # @return [Boolean}
            def single_shot?
                @single_shot == true
            end

            # Executes the code block tight to the timer and 
            # saves a time stamp.
            #
            # @param [Time] time The time stamp
            def call(time = Time.now)
                @last_call = time
                @result = @block.call
            end

            # Resets the timer internal time to the given one.
            #
            # @param [Time] time the time
            def reset(time = Time.now)
                @last_call = time
            end
        end

        # Error class which will be raised if a deferred operation calls 
        # raises an error.
        class EventLoopError < RuntimeError
            attr_reader :error
            attr_reader :object

            def initialize(message,object,error)
                super message
                @object = object
                @error = error
            end
        end

        # Underlying thread pool used to defer work.
        #
        # @return [Utilrb::ThreadPool]
        attr_reader :thread_pool

        # A new EventLoop
        def initialize
            @mutex = Mutex.new
            @events = []                 # stores all events for the next step
            @timers = []                 # stores all timers
            @every_cylce_events = []     # stores all events which are added to @events each step
            @on_error = {}               # stores on error callbacks
            @errors = []                 # stores errors which will be re raised at the end of the step
            @thread_pool = ThreadPool.new
        end

        # Integrates a blocking operation call into the EventLoop like {Utilrb::EventLoop#defer}
        # but has a more suitable syntax for deferring a method call
        #
        # If the callback has an arity of 2 the exception is passed to the
        # callback as second parameter and considered as handled. Otherwise 
        # the error is passed to the error handlers.
        #
        #    async &:my_method do |result,exception|
        #          if exception
        #                  raise exception
        #          else
        #                  puts result
        #          end
        #    end
        #
        # @param [#call] work The proc which will be deferred
        # @yield [result] The callback
        # @yield [result,exception] The callback
        # @return [Utilrb::ThreadPool::Task] The thread pool task.
        def async(work,*args,&callback)
            async_with_options(work,Hash.new,*args,&callback)
        end

        # (see #async)
        # @param [Hash] options The options
        # @option (see #defer)
        def async_with_options(work,options=Hash.new,*args,&callback)
            options[:callback] = callback
            defer(options,*args,&work)
        end

        # (see ThreadPool#sync)
        def sync(sync_key,*args,&block)
            thread_pool.sync(sync_key,*args,&block)
        end

        # Integrates a blocking operation call like {Utilrb::EventLoop#async}
        # but automatically re queues the call if period was passed and the
        # task was finished by the worker thread.  This means it will never re
        # queue the call if it blocks for ever and it will never simultaneously
        # defer the call to more than one worker thread.
        #
        # @param [Hash] options The options 
        # @option options [Float] :period The period
        # @param [#call] work The proc which will be deferred
        # @param (see #defer)
        # @option (see #defer)
        # @return [EventLoop::Timer] The thread pool task.
        def async_every(work,options=Hash.new,*args, &callback)
            options, async_opt = Kernel.filter_options(options,:period)
            period = options[:period]
            raise ArgumentError,"No period given" unless period
            task = nil
            every period do
                if !task
                    task = async_with_options(work,async_opt,*args,&callback)
                elsif task.finished?
                    self << task
                end
                task
            end
        end

        # Integrates a blocking operation call into the EventLoop by
        # executing it from a different thread. The given callback
        # will be called from the EventLoop thread while processing its events after
        # the call returned.
        #
        # If the callback has an arity of 2 the exception will be passed to the
        # callback as second parameter in an event of an error. The error is
        # also passed to the error handlers of the even loop. But it will not
        # be re raised if a default return value was set by the option
        # :default.
        #
        # To overwrite an error the callback can return :ignore_error or
        # a new instance of an error in an event of an error. In this
        # case the error handlers of the event loop will not be called
        # or called with the new error instance.
        #
        # @example ignore a error
        # callback = Proc.new do |r,e|
        #               if e
        #                  :ignore_error
        #               else
        #                  puts r
        #               end
        #            end 
        # defer({:callback => callback}) do
        #    raise
        # end
        #
        # @param [Hash] options The options 
        # @option (see ThreadPool::Task#initialize)
        # @option options [Proc] :callback The callback
        # 
        # @param (see ThreadPool::Task#initialize)
        # @return [ThreadPool::Task] The thread pool task.
        def defer(options=Hash.new,*args,&block)
            options, task_options = Kernel.filter_options(options,{:callback => nil})
            callback = options[:callback]

            task = Utilrb::ThreadPool::Task.new(task_options,*args,&block)
            # ensures that user callback is called from main thread and not from worker threads
            if callback
                task.callback do |result,exception|
                    once do
                        if callback.arity == 1
                            callback.call result if !exception || !task.default?
                        else
                            e = callback.call result,exception
                            #check if the error was overwritten in the
                            #case of an error
                            exception = if exception
                                            if e == :ignore_error
                                                nil
                                            elsif e.is_a? Exception
                                                e
                                            else
                                                exception
                                            end 
                                        end
                        end
                        if exception
                            if task.default?
                                #just inform all error handlers
                                handle_error(exception,false)
                            else
                                handle_error(exception,true)
                            end
                        end
                    end
                end
            else
                task.callback do |result,exception|
                    if exception
                        if task.default?
                            #just inform all error handlers
                            once do
                                handle_error(exception,false)
                            end
                        else
                            once do
                                handle_error(exception,true)
                            end
                        end
                    end
                end
            end
            @thread_pool << task
            task
        end

        # Executes the given block in the next step.
        #
        # @yield [] The code block.
        def once(delay=nil,&block)
            if delay && delay > 0
                timer = Timer.new(self,delay,true,&block)
                timer.start
            else
                @mutex.synchronize do
                    @events << block
                end
            end
        end

        # Returns true if events are queued 
        #
        # @return [Boolean]
        def events?
            @mutex.synchronize do
                !@events.empty? || !@errors.empty?
            end
        end

        # Adds a timer to the event loop which will execute 
        # the given code block with the given period
        #
        # @param [Float] period The period of the timer in seconds
        # @yield The code block.
        # @return [Utilrb::EventLoop::Timer]
        def every(period,&block)
            timer = Timer.new(self,period,&block)
            timer.start
        end

        # Executes the given block every step
        def every_step(&block)
            @mutex.synchronize do
                @every_cylce_events << block
            end
        end

        # Errors caught during event loop callbacks are forwarded to
        # registered code blocks. The code block is called from
        # the event loop thread.
        #
        # @param @error_class The error class the block should be called for
        # @yield [exception] The code block
        def on_error(error_class,&block)
            @mutex.synchronize do
                @on_error[error_class] ||= []
                @on_error[error_class]  << block
            end
        end

        # Errors caught during event loop callbacks are forwarded to
        # registered code blocks. The code blocks are called from 
        # the event loop thread.
        #
        # @param @error_classes The error classes the block should be called for
        # @yield [exception] The code block
        def on_errors(*error_classes,&block)
            error_classes.each do |error_class|
                on_error(error_class,&block)
            end
        end

        # Returns true if the given timer is running.
        #
        # @param [Timer] timer The timer.
        # @return [Boolean]
        def timer?(timer)
            @mutex.synchronize do
                @timers.include? timer
            end
        end

        # Cancels the given timer if it is running otherwise
        # it does nothing.
        # 
        # @param [Timer] timer The timer
        def cancel_timer(timer)
            @mutex.synchronize do
                @timers.delete timer
            end
        end



        # Resets all timers to fire not before their hole 
        # period is passed counting from the given point in time.
        #
        # @param [Time] time The time
        def reset_timer(time = Time.now)
            @mutex.synchronize do 
                @timers.each do |timer|
                    timer.reset time
                end
            end
        end

        # Starts the event loop with the given period. If a code
        # block is given it will be executed at the end of each step.
        # This method will block until stop is called
        #
        # @param [Float] period The period
        # @yield The code block
        def exec(period=0.05,&block)
            @stop = false
            reset_timer
            while !@stop
                last_step = Time.now
                step(last_step,&block)
                diff = (Time.now-last_step).to_f
                sleep(period-diff) if diff < period && !@stop
            end
        end

        # Stops the EventLoop after [#exec] was called.
        def stop
            @stop = true
        end

        # Steps with the given period as long as the given 
        # block returns false.
        #
        # @param [Float] period The period 
        # @yieldreturn [Boolean]
        def wait_for(period=0.05,&block)
            exec period do 
                stop if block.call
            end
        end

        # Steps with the given period until all
        # worker thread are waiting for work
        #
        # @param [Float] period Ther period
        # @param (@see #step)
        def steps(period = 0.05,&block)
            while thread_pool.process? || events? 
                last_step = Time.now
                step(last_step,&block)
                diff = (Time.now-last_step).to_f
                sleep(period-diff) if diff < period && !@stop
            end
        end

        # (see ThreadPool#backlog)
        def backlog
            thread_pool.backlog
        end

        # Shuts down the thread pool
        def shutdown()
            thread_pool.shutdown()
        end

        # Handles all current events and timers. If a code
        # block is given it will be executed at the end.
        #
        # @param [Time] time The time the step is executed for.
        # @yield The code block
        def step(time = Time.now,&block)
            #copy all work otherwise it would not be allowed to 
            #call any event loop functions from a callback or timer
            events,timers,call = @mutex.synchronize do
                                    raise @errors.shift if !@errors.empty?
                                    temp_event = @events+@every_cylce_events
                                    @events.clear

                                    # check all timers
                                    temp_timers = @timers.find_all do |timer|
                                        timer.timeout?(time)
                                    end

                                    # delete single shot timer
                                    @timers -= temp_timers.find_all(&:single_shot?)
                                    [temp_event,temp_timers,block]
                                end

            events.each do |event|
                handle_errors{event.call}
            end
            timers.each do |timer|
                handle_errors{timer.call(time)}
            end

            handle_errors{call.call} if block
            @mutex.synchronize do 
                raise @errors.shift if !@errors.empty?
            end
        end

        # Adds an object to the event loop 
        #
        # @overload <<(proc)
        #   @param [Proc] If arity = 0 it will be forwarded to [#once] otherwise to [#error_handler]
        #   @raise [ArgumentError] if arity > 1 or argument is not a [Proc]
        # @overload <<(timer)
        #   @param [Timer] timer The timer which will be added 
        #   @raise [ArgumentError] if argument is not a [Timer]
        # @overload <<(task)
        #   @param [ThreadPool::Task] task The task which will be added 
        #   @raise [ArgumentError] if argument is not a [ThreadPool::Task]
        def <<(object,&block)
            self << block if block
            if object
                if object.is_a? Timer
                    @mutex.synchronize do
                        @timers << object unless @timers.include? object
                    end
                elsif object.is_a? Proc
                    if object.arity == 0
                        once(nil,&object)
                    elsif object.arity == 1
                        error_handler(&object)
                    else
                        raise ArgumentError
                    end
                elsif object.is_a? ThreadPool::Task
                    thread_pool << object
                else
                    raise ArgumentError
                end
            end
        rescue ArgumentError => e
            raise ArgumentError, "Do not know how to add #{object} to the event loop."
        end

        # Clears all timers, events and errors
        def clear
            @mutex.synchronize do
                @errors.clear
                @timers.clear
                @events.clear
            end
        end

        # Clears all errors which occurred during the last step and cannot be
        # handled by the error handlers. If the errors were not cleared they are
        # re raised the next time raise is called.
        def clear_errors
            @mutex.synchronize do
                @errors.clear
            end
        end

    private
        # Calls the given block and rescues all errors which can be handled
        # by the added error handler. If an error cannot be handled it is 
        # stored and re raised after all events and timers are processed. If
        # more than one error occurred which cannot be handled they are stored 
        # until the next step is called and re raised until all errors are processed.
        #
        # @info This method must be called from the event loop thread, otherwise
        #    all error handler would be called from the wrong thread
        #
        # @yield The code block.
        # @see #error_handler
        def handle_errors(&block)
            block.call
        rescue Exception => e
            handle_error(e,true)
        end

        # @info This method must be called from the event loop thread, otherwise
        #    all error handler would be called from the wrong thread
        def handle_error(error,save = true)
            on_error = @mutex.synchronize do
                @on_error.find_all{|key,e| error.is_a? key}.map(&:last).flatten
            end
            on_error.each do |handler|
                handler.call error
            end

            if save
                @mutex.synchronize do
                    @errors <<  error
                end
            end
        end

    public
        # The EventLoop::Forwardable module provides delegation of specified methods to
        # a designated object like the ruby ::Forwardable module but defers the
        # method call to a thread pool of an event loop if a callback is given.
        # After the call returned the callback is called from the event loop thread
        # while it is processing its event at the end of each step.
        #
        # To ensure thread safety for all kind of objects the event loop defers
        # only one method call per object in parallel even if the method is
        # called without any callback. For this mechanism a sync key is used
        # which is by default the designated object but can be set to any
        # custom ruby object. If a method call is thread safe the sync key can
        # be set to nil allowing the event loop to call it in parallel while
        # another none thread safe method call of the designated object is processed.
        #
        # @note It is not possible to delegate methods where the target method needs
        #    a code block.
        #
        # @author Alexander Duda <Alexander.Duda@dfki.de>
        module Forwardable
            # Runtime error raised if the designated object is nil
            # @author Alexander Duda <Alexander.Duda@dfki.de>
            class DesignatedObjectNotFound < RuntimeError; end

            # Defines a method as delegator instance method with an optional alias
            # name ali and a second method postfixed with _every.
            #
            # Method calls to ali will be delegated to accessor.method.
            #
            # Method calls to ali(*args,&block) will be delegated to
            # accessor.method(*args) but called from a thread pool.  Thereby the code
            # block is used as callback called from the main thread after the
            # call returned.
            #
            # Method calls to ali_every(period,args,&block) will be
            # delegated to accessor.method(*args) but called from a thread pool
            # with the given period.
            #
            # For exception handling the callback can be used:
            #    ali do |result,exception|
            #    end
            #    ali_every 0.1 do |result,exception|
            #    end
            #
            # If the callback accepts only one argument the error handlers from
            # the underlying event loop are used to handle the error. If no
            # handle can handle the error it is re raised at the end of the
            # event loop step.
            #    ali do |result|
            #    end
            #    ali_every 0.1 do |result|
            #    end
            #    
            # If the result shall be filtered before returned a filter method can
            # be specified which is called from the event loop thread just before
            # the result is returned.
            #
            # @example
            #       class Dummy
            #           # non thread safe method
            #           def test(wait)
            #               sleep wait
            #               Thread.current
            #           end
            #
            #           # thread safe method
            #           def test_thread_safe(wait)
            #               sleep wait
            #               Thread.current
            #           end
            #       end
            #       class DummyAsync
            #           extend Utilrb::EventLoop::Forwardable
            #           def_event_loop_delegator :@obj,:@event_loop,:test,:alias => :atest
            #           def_event_loop_delegator :@obj,:@event_loop,:test_thread_safe,:sync_key => false
            #
            #           def initialize(event_loop)
            #               @event_loop = event_loop
            #               @obj = Dummy.new
            #           end
            #       end
            #
            #       event_loop = EventLoop.new
            #       test = DummyAsync.new(event_loop)
            #       puts test.atest(2)
            #       test.atest_every(1,2) do |result|
            #           puts result
            #       end
            #       test.thread_safe_every(1,2) do |result|
            #           puts result
            #       end
            #       event_loop.exec
            #
            # @param [Symbol] accessor The symbol for the designated object.
            # @param [Symbol] event_loop The event loop accessor.
            # @param [Symbol] method The method called on the designated object.
            # @param [Hash] options The options 
            # @option options [Symbol] :alias The alias of the method
            # @option options [Symbol] :sync_key The sync key 
            # @option options [Symbol] :filter The filter method
            # @option options [Object] :default Default value returned
            # @option options [Exception] :error Exception which will be raised
            #   if the underlying object is nil and no default value is set
            # @see #sync
            def def_event_loop_delegator(accessor,event_loop, method, options = Hash.new )
                Forward.def_event_loop_delegator(self,accessor,event_loop,method,options)
            end

            def def_event_loop_delegators(accessor,event_loop, *methods)
                Forward.def_event_loop_delegators(self,accessor,event_loop,*methods)
            end

            def forward_to(accessor,event_loop,options = Hash.new,&block)
                obj = Forward.new(self,accessor,event_loop,options)
                obj.instance_eval(&block)
            end

        private
            class Forward
                def initialize(klass,accessor,event_loop,options = Hash.new)
                    @klass = klass
                    @stack = [options]
                    @accessor = accessor
                    @event_loop = event_loop
                end

                def options(options = Hash.new,&block)
                    @stack << @stack.last.merge(options)
                        block.call
                    @stack.pop
                end

                def thread_safe(&block)
                    options :sync_key => nil do 
                        block.call
                    end
                end

                def def_delegators(*methods)
                    options = if methods.last.is_a? Hash
                                  methods.pop
                              else
                                  Hash.new
                              end
                    methods << @stack.last.merge(options)
                    Forward.def_event_loop_delegators(@klass,@accessor,@event_loop,*methods)
                end

                def def_delegator(method,options = Hash.new)
                    options = @stack.last.merge options
                    Forward.def_event_loop_delegator(@klass,@accessor,@event_loop,method,options)
                end


                def self.def_event_loop_delegator(klass,accessor,event_loop, method, options = Hash.new )
                    options = Kernel.validate_options options, :filter => nil,:alias => method,:sync_key => accessor,:default => :_no_default
                    raise ArgumentError, "accessor is nil" unless accessor
                    raise ArgumentError, "event_loop is nil" unless event_loop
                    raise ArgumentError, "method is nil" unless method

                    ali = options[:alias]
                    return if klass.instance_methods.include? ali.to_sym

                    ali =~ /(.*\w)(.*)/
                    ali_every = "#{$1}_every#{$2}"
                    ali_every = nil if($2 =~ /.*=$/)

                    filter = options[:filter]
                    sync_key = options[:sync_key]
                    sync_key ||= :nil
                    default = options[:default].inspect

                    line_no = __LINE__; str = %Q{
                    def #{ali}(*args, &block)
                      begin
                        options = Hash.new
                        accessor,error = #{accessor} # cache the the accessor.
                        if !block
                            if !accessor
                                #{if options[:default] == :_no_default
                                    "if error 
                                        raise error
                                     else 
                                        raise DesignatedObjectNotFound,'designated object is nil'
                                     end"
                                else
                                    filter ? "#{filter}(#{default})" : default
                                end}
                            else
                                result = #{sync_key ? "#{event_loop}.sync(#{sync_key}){accessor.__send__(:#{method}, *args)}" : "accessor.__send__(:#{method}, *args)"}
                                #{filter ? "#{filter}(result)" : "result"}
                            end
                        else
                            work = Proc.new do |*args|
                                    acc,err = #{accessor} # cache accessor
                                    if !acc
                                        if err
                                            raise err
                                        else
                                            raise DesignatedObjectNotFound,'designated object is nil'
                                        end
                                    else
                                        acc.__send__(:#{method}, *args)
                                    end
                                end
                            callback = #{filter ? "block.to_proc.arity == 2 ? Proc.new { |r,e| block.call(#{filter}(r),e)} : Proc.new {|r| block.call(#{filter}(r))}" : "block"}
                            #{event_loop}.async_with_options(work,{:sync_key => #{sync_key},:default =>#{default}},*args, &callback)
                        end
                      rescue Exception
                        $@.delete_if{|s| %r"#{Regexp.quote(__FILE__)}"o =~ s}
                        ::Kernel::raise
                      end
                    end
                    #{if ali_every
                        %Q{
                        def #{ali_every}(period,*args, &block)
                          begin
                            if !block
                                raise ArgumentError, "No block is given"
                            else
                                task = nil
                                #{event_loop}.every period do
                                    if !task
                                        task = #{ali}(*args,&block)
                                    elsif task.finished?
                                        #{event_loop} << task
                                    end
                                    task
                                end
                            end
                          rescue Exception
                            $@.delete_if{|s| %r"#{Regexp.quote(__FILE__)}"o =~ s}
                            ::Kernel::raise
                          end
                        end}
                     end}
                    }
                    # If it's not a class or module, it's an instance
                    begin
                        klass.module_eval(str, __FILE__, line_no)
                    rescue
                        klass.instance_eval(str, __FILE__, line_no)
                    end
                end

                # Defines multiple method as delegator instance methods 
                # @see #def_event_loop_delegator
                def self.def_event_loop_delegators(klass,accessor,event_loop, *methods)
                    methods.flatten!
                    options = if methods.last.is_a? Hash
                                  methods.pop
                              else
                                  Hash.new
                              end
                    options = Kernel.validate_options options, :filter => nil,:sync_key => nil,:default =>:nil
                    methods.each do |method|
                        def_event_loop_delegator(klass,accessor,event_loop,method,options)
                    end
                end
            end
        end

    end
end
