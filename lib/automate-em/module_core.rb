module AutomateEm
	module ModuleCore
		include Status	# The observable pattern (Should not be called directly)
		include Constants
		include Utilities
		
		#
		# Sets up a link for the user code to the eventmachine class
		#	This way the namespace is clean.
		#
		def setbase(base)
			@base = base
			class << self
				undef setbase
			end
		end
		
		
		def join_system(system)
			@system_lock.synchronize {
				@systems << system
			}
		end
		
		def leave_system(system)
			@system_lock.synchronize {
				@systems.delete(system)
				return @systems.length
			}
		end
		
		def clear_active_timers
			@schedule.clear_jobs unless @schedule.nil?
		end
		
		
		#def command_successful(result)			# TODO:: needs a re-think
		#	@base.process_data_result(result)
		#end
		

		def logger
			@system_lock.synchronize {
				return @systems[0].logger unless @systems.empty?
			}
			System.logger
		end
		
		attr_reader :systems
		attr_reader :base
		
		
		protected
		
		
		#
		# Configuration and settings
		# => Get all zones that the pod is in with the setting set and select the first setting
		# => TODO:: Replace this with NoSQL
		#
		def setting(name)
			val = config.settings.where("name = ?", name.to_s).first
			if val.nil?
				val = config.control_system.zones.joins(:settings).where('settings.name = ?', name.to_s).first
				val = val.settings.where("name = ?", name.to_s).first unless val.nil?
				
				val = config.dependency.settings.where("name = ?", name.to_s).first if val.nil?
			end
			
			if val.present?
				case val.value_type
					when 0
						return val.text_value
					when 1
						return val.integer_value
					when 2
						return val.float_value
					when 3
						return val.datetime_value
				end
			end
			
			return nil
		end
	end
end