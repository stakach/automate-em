require 'atomic'

#
# This contains the basic constructs required for
#	serialised comms over TCP and UDP
#
module AutomateEm
	module DeviceConnection
		def initialize( parent, udp )
			#super
		
			@default_send_options = {
				:wait => true,			# Wait for response
				:delay => 0,			# Delay next send by x.y seconds
				:delay_on_receive => 0,	# Delay next send after a receive by x.y seconds (only works when we are waiting for responses)
				#:emit
				:max_waits => 3,
				:callback => nil,		# Alternative to the received function
				:retries => 2,
				:hex_string => false,
				:timeout => 5,			# Timeout in seconds
				:priority => 50,
				:retry_on_disconnect => true,
				:force_disconnect => false	# part of make and break options
			}
			
			@config = {
				:max_buffer => 524288,		# 512kb
				:clear_queue_on_disconnect => false,
				:flush_buffer_on_disconnect => false,
				:priority_bonus => 20
				# :inactivity_timeout => 0	# part of make and break options
				# :response_length			# an alternative to response_delimiter (lower priority)
			}
			
			
			#
			# Queues
			#
			@task_queue = EM::Queue.new		# basically we add tasks here that we want to run in a strict order (connect, disconnect)
			@receive_queue = EM::Queue.new	# So we can process responses in different ways
			@wait_queue = EM::Queue.new
			@send_queue = EM::PriorityQueue.new(:fifo => true) {|x,y| (x || 50) < (y || 50)} # regular priority
			
			#
			# Named commands
			#	Allowing for state control
			#
			@named_commands = {}
			
			#
			# Locks
			#
			@received_lock = Mutex.new
			@task_lock = Mutex.new
			@status_lock = Mutex.new
			@send_monitor = Object.new.extend(MonitorMixin)
			
			
			#
			# State
			#
			@connected = udp
			@connecting = false
			@disconnecting = false
			@com_paused = true
			
			@command = nil
			@waiting = false
			@processing = false
			@last_sent_at = 0.0
			@last_receive_at = 0.0
			@timeout = nil
			
			
			#
			# Configure links between objects (This is a very loose tie)
			#	Relies on serial loading of modules
			#
			@parent = parent
			@parent.setbase(self)
			
			@tls_enabled = @parent.secure_connection
			if @parent.makebreak_connection
				@make_break = true
				@first_connect = true
			else
				@make_break = false
			end
			@make_occured = false
			
			@shutting_down = Atomic.new(false)
			
			
			#
			# Task event loop
			#
			@task_queue_proc = Proc.new do |task|
				if !@shutting_down.value
					EM.defer do
						begin
							@task_lock.synchronize {
								task.call
							}
						rescue => e
							AutomateEm.print_error(logger, e, {
								:message => "module #{@parent.class} in device_connection.rb, base : error in task loop",
								:level => Logger::ERROR
							})
						ensure
							ActiveRecord::Base.clear_active_connections!
							@task_queue.pop &@task_queue_proc
						end
					end
				end
			end
			@task_queue.pop &@task_queue_proc	# First task is ready
			
			
			#
			# Module loaded
			#
			@task_queue.push lambda {
				if @parent.respond_to?(:on_load)
					begin
						@parent.on_load
					rescue => e
						AutomateEm.print_error(logger, e, {
							:message => "device module #{@instance.class} error whilst calling: on_load",
							:level => Logger::ERROR
						})
					ensure
						ActiveRecord::Base.clear_active_connections!
					end
				end
			}
			
			
			#
			# send loop
			#
			@wait_queue_proc = Proc.new do |ignore|
				if ignore != :shutdown
				
					@send_queue.pop {|command|
						if command != :shutdown
							begin
								
								process = true
								if command[:name].present?
									begin
										name = command[:name]
										@named_commands[name][0].pop				# Extract the command data
										command = @named_commands[name][1]
										
										if @named_commands[name][0].empty?			# See if any more of these commands are queued
											@named_commands.delete(name)	# Delete if there are not
										else
											@named_commands[name][1] = nil			# Reset if there are
										end
										
										if command.nil?								# decide if to continue or not
											command = {}
											process = false
										end
									rescue
										#
										# Retry (pop empty, lets let it have it)
										#
									end
								end
								
								if process
									if command[:delay] > 0.0
										delay = @last_sent_at + command[:delay] - Time.now.to_f
										if delay > 0.0
											EM.add_timer delay do
												process_send(command)
											end
										else
											process_send(command)
										end
									else
										process_send(command)
									end
								else
									process_next_send(command)
								end
							rescue => e
								EM.defer do
									AutomateEm.print_error(logger, e, {
										:message => "module #{@parent.class} in device_connection.rb, base : error in send loop",
										:level => Logger::ERROR
									})
								end
							ensure
								ActiveRecord::Base.clear_active_connections!
								@wait_queue.pop &@wait_queue_proc
							end
						end
					}
				end
			end
			
			#@wait_queue.push(nil)		Start paused
			@wait_queue.pop &@wait_queue_proc
		end
		
		
		def process_send(command)	# this is on the reactor thread
			begin
				if !error? && @connected
					do_send_data(command[:data])
					
					@last_sent_at = Time.now.to_f
					@waiting = command[:wait]
					
					if @waiting
						@command = command
						@timeout = EM::Timer.new(command[:timeout]) {
							sending_timeout
						}
					else
						process_next_send(command)
					end
				else
					if @connected
						process_next_send(command)
					else
						if command[:retry_on_disconnect] || @make_break
							@send_queue.push(command, command[:priority] - (2 * @config[:priority_bonus]))	# Double bonus
						end
						@com_paused = true
					end
				end
			rescue => e
				#
				# Save the thread in case of bad data in that send
				#
				EM.defer do
					AutomateEm.print_error(logger, e, {
						:message => "module #{@parent.class} in device_connection.rb, process_send : possible bad data",
						:level => Logger::ERROR
					})
				end
				if @connected
					process_next_send(command)
				else
					@com_paused = true
				end
			end
		end
		
		def process_next_send(command)
			if command[:force_disconnect]		# Allow connection control
				close_connection_after_writing
				@disconnecting = true
				@com_paused = true
			else
				EM.next_tick do
					@wait_queue.push(nil)	# Allows next response to process
				end
			end
		end
		
		#
		# Data received
		#	Allow modules to set message delimiters for auto-buffering
		#	Default max buffer length == 1mb (setting can be overwritten)
		#	NOTE: The buffer cannot be defered otherwise there are concurrency issues 
		#
		def do_receive_data(data)
			@last_receive_at = Time.now.to_f
			
			begin
				if @parent.respond_to?(:response_delimiter)
					if @buf.nil?
						del = @parent.response_delimiter
						if del.class == Array
							del = array_to_str(del)
						elsif del.class == Fixnum
							del = "" << del #array_to_str([del & 0xFF])
						end
						@buf = BufferedTokenizer.new(del, @config[:max_buffer])    # Call back for character
					end
					data = @buf.extract(data)
				elsif @config[:response_length].present?
					(@buf ||= "") << data
					data = @buf.scan(/.{1,#{@config[:response_length]}}/)
					if data[-1].length == @config[:response_length]
						@buf = nil
					else
						@buf = data[-1]
						data = data[0..-2]
					end
				else
					data = [data]
				end
			rescue => e
				@buf = nil	# clear the buffer
				EM.defer do # Error in a thread
					AutomateEm.print_error(logger, e, {
						:message => "module #{@parent.class} error whilst setting delimiter",
						:level => Logger::ERROR
					})
				end
				data = [data]
			end
			
			if @waiting && data.length > 0
				if @processing
					@receive_queue.push(*data)
				else
					@processing = true
					@timeout.cancel if @timeout.respond_to? :cancel
					process_response(data.shift, @command)
					if data.length > 0
						@receive_queue.push(*data)
					end
				end
			else
				data.each do |result|
					process_response(result, nil)
				end
			end
		end
		
		
		#
		# Called from receive
		#
		def process_response(response, command)
			EM.defer do
				do_process_response(response, command)
			end
		end
		
		def do_process_response(response, command)
			return if @shutting_down.value
			
			@received_lock.synchronize { 	# This lock protects the send queue lock when we are emiting status
				@send_monitor.mon_synchronize {
					result = :abort
					begin
						if @parent.respond_to?(:received)
							if command.present?
								@parent.mark_emit_start(command[:emit]) if command[:emit].present?
								if command[:callback].present?
									result = command[:callback].call(response, command)
									
									#
									# The data may still be usefull
									#
									if [nil, :ignore].include?(result)
										@parent.received(response, nil)
									end
								else
									result = @parent.received(response, command)
								end
							else
								#	logger.debug "Out of order response received for: #{@parent.class}"
								result = @parent.received(response, nil)
							end
						else
							if command.present? 
								@parent.mark_emit_start(command[:emit]) if command[:emit].present?
								if command[:callback].present?
									result = command[:callback].call(response, command)
								else
									result = true
								end
							else
								result = true
							end
						end
					rescue => e
						#
						# save from bad user code (don't want to deplete thread pool)
						#	This error should be logged in some consistent manner
						#
						AutomateEm.print_error(logger, e, {
							:message => "module #{@parent.class} error whilst calling: received",
							:level => Logger::ERROR
						})
					ensure
						if command.present?
							@parent.mark_emit_end if command[:emit].present?
						end
						ActiveRecord::Base.clear_active_connections!
					end
					
					if command.present? && command[:wait]
						EM.schedule do
							process_result(result)
						end
					end
				}
			}
		end
		
		
		def sending_timeout
			@timeout = true
			if !@processing && @connected && @command.present?	# Probably not needed...
				@processing = true	# Ensure responses go into the queue
				
				command = @command[:data]
				process_result(:failed)
				
				EM.defer do
					logger.info "module #{@parent.class} timeout"
					logger.info "A response was not received for the command: #{command}" unless command.nil?
				end
			elsif !@connected && @command.present? && @command[:wait]
				if @command[:retry_on_disconnect] || @make_break
					@send_queue.push(@command, @command[:priority] - (2 * @config[:priority_bonus]))	# Double bonus
				end
				@com_paused = true
			end
		end
		
		
		def process_result(result)
			if [nil, :ignore].include?(result) && @command[:max_waits] > 0
				@command[:max_waits] -= 1
				
				if @receive_queue.size() > 0
					@receive_queue.pop { |response|
						process_response(response, @command)
					}
				else
					@timeout = EM::Timer.new(@command[:timeout]) {
						sending_timeout
					}
					@processing = false
				end
			else
				if [false, :failed].include?(result) && @command[:retries] > 0	# assume command failed, we need to retry
					@command[:retries] -= 1
					@send_queue.push(@command, @command[:priority] - @config[:priority_bonus])
				end
				
				#else    result == :abort || result == :success || result == true || waits and retries exceeded
				
				@receive_queue.size().times do
					@receive_queue.pop { |response|
						process_response(response, nil)
					}
				end
				
				@processing = false
				@waiting = false
				
				if @command[:delay_on_receive] > 0.0
					delay_for = (@last_receive_at + @command[:delay_on_receive] - Time.now.to_f)
					
					if delay_for > 0.0
						EM.add_timer delay_for do
							process_response_complete
						end
					else
						process_response_complete
					end
				else
					process_response_complete
				end
			end
		end
		
		def process_response_complete
			if (@make_break && [nil, 0].include?(@config[:inactivity_timeout]) && @send_queue.empty?) || @command[:force_disconnect]
				if @connected
					close_connection_after_writing
					@disconnecting = true
				end
				@com_paused = true
			else
				EM.next_tick do
					@wait_queue.push(nil)
				end
			end
			
			@command = nil 			# free memory
		end
		
		
		
		
		#
		# ----------------------------------------------------------------
		# Everything below here is called from a deferred thread
		#
		#
		def logger
			@parent.logger
		end
		
		def received_lock
			@send_monitor		# for monitor use
		end
		
		
		#
		# Processes sends in strict order
		#
		def do_send_command(data, options = {}, *args, &block)
			
			begin
				@status_lock.synchronize {
					options = @default_send_options.merge(options)
				}
				
				#
				# Make sure we are sending appropriately formatted data
				#
				if data.is_a?(Array)
					data = array_to_str(data)
				elsif options[:hex_string] == true
					data = hex_to_byte(data)
				end
				
				options[:data] = data
				options[:retries] = 0 if options[:wait] == false
				
				if options[:callback].nil? && (args.length > 0 || block.present?)
					options[:callback] = args[0] unless args.empty? || args[0].class != Proc
					options[:callback] = block unless block.nil?
				end
				
				if options[:name].present?
					options[:name] = options[:name].to_sym
				end
			rescue => e
				AutomateEm.print_error(logger, e, {
					:message => "module #{@parent.class} in device_connection.rb, send : possible bad data or options hash",
					:level => Logger::ERROR
				})
				
				return true
			end
				
				
			#
			# Use a monitor here to allow for re-entrant locking
			#	This allows for a priority queue and we guarentee order of operations
			#
			bonus = false
			begin
				@send_monitor.mon_exit
				@send_monitor.mon_enter
				bonus = true
			rescue
			end
			
			EM.schedule do
				if bonus
					options[:priority] -= @config[:priority_bonus]
				end
				add_to_queue(options)
			end
				
			return false
		rescue => e
			#
			# Save from a fatal error
			#
			AutomateEm.print_error(logger, e, {
				:message => "module #{@parent.class} in device_connection.rb, send : something went terribly wrong to get here",
				:level => Logger::ERROR
			})
			return true
		end
		
		def add_to_queue(command)
			begin
				command[:priority] = 50 unless command[:priority].is_a? Fixnum
				if @connected || @make_break
					if @com_paused && !@make_break									# We are calling from connected function (and we are connected)
						command[:priority] -=  (2 * @config[:priority_bonus])		# Double bonus
					elsif @make_break
						if !@connected && !@connecting
							EM.next_tick do
								do_connect
							end
						elsif @connected && @disconnecting
							EM.next_tick do
								add_to_queue(command)
							end
							return	# Don't add to queue yet
						end
					end
					
					add = true
					if command[:name].present?
						name = command[:name]
						if @named_commands[name].nil?
							@named_commands[name] = [[command[:priority]], command]	#TODO:: we need to deal with the old commands emit values!
						elsif @named_commands[name][0][-1] > command[:priority]
							@named_commands[name][0].push(command[:priority])
							@named_commands[name][1] = command						#TODO:: we need to deal with the old commands emit values!
						else
							@named_commands[name][1] = command						#TODO:: we need to deal with the old commands emit values!
							add = false
						end
					end
					
					@send_queue.push(command, command[:priority]) if add
				end
			rescue => e
				EM.defer do
					AutomateEm.print_error(logger, e, {
						:message => "module #{@parent.class} in device_connection.rb, send : something went terribly wrong to get here",
						:level => Logger::ERROR
					})
				end
			end
		end
		
		
		
		
		#
		# Connection state
		#
		def call_connected(*args)
			#
			# NOTE:: Same as add parent in device module!!!
			#	TODO:: Should break into a module and include it
			#
			set_comm_inactivity_timeout(@config[:inactivity_timeout]) unless @config[:inactivity_timeout].nil?
			@task_queue.push lambda {
				@parent[:connected] = true
				
				begin
					@send_monitor.mon_synchronize { # Any sends in here are high priority (no emits as this function must return)
						@parent.connected(*args) if @parent.respond_to?(:connected)
					}
				rescue => e
					#
					# save from bad user code (don't want to deplete thread pool)
					#
					AutomateEm.print_error(logger, e, {
						:message => "module #{@parent.class} error whilst calling: connect",
						:level => Logger::ERROR
					})
				ensure
					EM.schedule do
						#
						# First connect if no commands pushed then we disconnect asap
						#
						if @make_break && @first_connect && @send_queue.size == 0
							close_connection_after_writing
							@disconnecting = true
							@com_paused = true
							@first_connect = false
						elsif @com_paused
							@com_paused = false
							@wait_queue.push(nil)
						else
							EM.defer do
								logger.info "Reconnected, communications not paused."
							end
						end
					end
				end
			}
		end
		
		
		
		def default_send_options= (options)
			@status_lock.synchronize {
				@default_send_options.merge!(options)
			}
		end
		
		def config= (options)
			EM.schedule do
				@config.merge!(options)
			end
		end
		
		
		
		
		def shutdown(system)
			if @parent.leave_system(system) == 0
				@shutting_down.value = true
				
				close_connection
				
				@wait_queue.push(:shutdown)
				@send_queue.push(:shutdown, -32768)
				@task_queue.push(nil)
				
				EM.defer do
					begin
						@parent[:connected] = false	# Communicator off at this point
						if @parent.respond_to?(:disconnected)
							@task_lock.synchronize {
								@parent.disconnected
							}
						end
					rescue => e
						#
						# save from bad user code (don't want to deplete thread pool)
						#
						AutomateEm.print_error(logger, e, {
							:message => "module #{@parent.class} error whilst calling: disconnected on shutdown",
							:level => Logger::ERROR
						})
					ensure
						@parent.clear_active_timers
						ActiveRecord::Base.clear_active_connections!
					end
				end
			end
		end
		
	end
end
