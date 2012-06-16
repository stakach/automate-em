module AutomateEm
	class Device
		include ModuleCore
		
		def initialize(tls, makebreak)
			@systems = []

			#
			# Status variables
			#	NOTE:: if changed then change in logic.rb 
			#
			@secure_connection = tls
			@makebreak_connection = makebreak
			@status = {}
			@status_lock = Object.new.extend(MonitorMixin)
			@system_lock = Mutex.new
			@status_waiting = false
		end

		
		

		#
		# required by base for send logic
		#
		attr_reader :secure_connection
		attr_reader :makebreak_connection
		

		protected
		
		
		def config
			DeviceModule.lookup(self)
		end
		

		def send(data, options = {}, *args, &block)
			error = true
			
			begin
				error = @base.do_send_command(data, options, *args, &block)
			rescue => e
				AutomateEm.print_error(logger, e, {
					:message => "module #{self.class} in send",
					:level => Logger::ERROR
				})
			ensure
				if error
					begin
						logger.warn "Command send failed for: #{data.inspect}"
					rescue
						logger.error "Command send failed, unable to print data"
					end
				end
			end
		end
	end
end
