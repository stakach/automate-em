module AutomateEm
	class System
		@@controllers = {0 => self}						# controller_id => system instance	(0 is the system class)
		@@logger = nil
		@@communicator = AutomateEm::Communicator.new(self)	# TODO:: remove the need for communicator.start
		@@communicator.start(true)
		@@god_lock = Mutex.new
		
		
		
		#
		# Error thrown means: mark as offline, do not retry and email
		# Return false means: retry and email if a second attempt fails
		# Return true means: all is good! system running
		#
		def self.start(controller, log_level = Logger::INFO)
			begin
				
				#
				# Ensure we are dealing with a controller
				#
				if controller.class == Fixnum
					controller = ControlSystem.find(controller)
				elsif controller.class == String
					controller = ControlSystem.where('name = ?', controller).first
				end
				
				if controller.class != ControlSystem
					raise 'invalid controller identifier'
				end
				
				
				#
				# Check if the system is already loaded or loading
				#
				@@god_lock.synchronize {
					if @@controllers[controller.id].present?
						return true
					end
					
					begin
						controller.reload(:lock => true)
						if controller.active
							return true
						else
							controller.active = true
						end
					ensure
						controller.save
					end
				}
				
				#
				# Create the system
				#
				system = System.new(controller, log_level)
				
				#
				# Load modules here (Producer)
				#
				proceed = Atomic.new(true)
				queue = Queue.new
				producer = Thread.new do	# New thread here to prevent circular waits on the thread pool
					begin
						controller.devices.includes(:dependency).each do |device|
							theClass = Modules.lazy_load(device.dependency)
							raise "Load Error" if theClass == false
							queue.push([device, theClass])
						end
						
						controller.services.includes(:dependency).each do |service|
							theClass = Modules.lazy_load(service.dependency)
							raise "Load Error" if theClass == false
							queue.push([service, theClass])
						end
						
						controller.logics.includes(:dependency).each do |logic|
							theClass = Modules.lazy_load(logic.dependency)
							raise "Load Error" if theClass == false
							queue.push([logic, theClass])
						end
					rescue
						proceed.value = false
					ensure
						ActiveRecord::Base.clear_active_connections!	# Clear any unused connections
						queue.push(:done)
					end
				end
				
				#
				# Consume the newly loaded modules here (Consumer)
				#
				mod = queue.pop
				while mod.is_a?(Array) && proceed.value == true
					begin
						system.load(*mod)
						
						mod = queue.pop
					rescue => e
						AutomateEm.print_error(@@logger, e, {
							:message => "Error stopping system after problems starting..",
							:level => Logger::ERROR
						})
						
						proceed.value = false
					end
				end
				
				
				#
				# Check if system modules loaded properly
				#
				if proceed.value == false
					#
					# Unload any loaded modules
					#
					system.stop
					
					return false
				end
				
				
				#
				# Setup the systems link
				#
				@@god_lock.synchronize {
					@@controllers[controller.id] = system
				}
				system.start	# Start the systems communicator
				return true
			ensure
				ActiveRecord::Base.clear_active_connections!	# Clear any unused connections
			end
		end
		
		
		#
		# Reloads a dependency live
		#	This is the re-load code function (live bug fixing - removing / adding / modifying functions)
		#
		def self.reload(dep)
			System.logger.info "reloading dependency: #{dep}"
			
			dep = Dependency.find(dep)
			Modules.load_module(dep)
			
			updated = {}
			dep.devices.select('id').each do |dev|
				begin
					inst = DeviceModule.instance_of(dev.id)
					inst.on_update if (!!!updated[inst]) && inst.respond_to?(:on_update)
				ensure
					updated[inst] = true
				end
			end
			
			updated = {}
			dep.services.select('id').each do |ser|
				begin
					inst = ServiceModule.instance_of(ser.id)
					inst.on_update if (!!!updated[inst]) && inst.respond_to?(:on_update)
				ensure
					updated[inst] = true
				end
			end
			
			updated = {}
			dep.logics.select('id').each do |log|
				begin
					inst = LogicModule.instance_of(log.id)
					inst.on_update if (!!!updated[inst]) && inst.respond_to?(:on_update)
				ensure
					updated[inst] = true
				end
			end
			
			ActiveRecord::Base.clear_active_connections!	# Clear any unused connections
		end
		
		#
		# Allows for system updates on the fly
		#	Dangerous (Could be used to add on the fly interfaces)
		#
		def self.force_load_file(path)
			load path if File.exists?(path) && File.extname(path) == '.rb'
		rescue LoadError => e	# load error explicitly handled
			AutomateEm.print_error(System.logger, e, {
				:message => "force load of #{path} failed",
				:level => Logger::ERROR
			})
		end
		
		
		#
		# System Logger
		#
		def self.logger
			@@logger
		end
		
		def self.logger=(log)
			@@logger = log
		end
		
		def self.communicator
			@@communicator
		end
		
		def self.[] (system)
			if system.is_a?(Symbol) || system.is_a?(String)
				system = ControlSystem.where('name = ?', system.to_s).pluck(:id).first
			end
			
			@@god_lock.synchronize {
				@@controllers[system]
			}
		end
		
		
		
		#
		# For access via communicator as a super user
		#
		def self.modules
			self
		end
		def self.instance
			self
		end
		def instance
			self
		end
		# ---------------------------------
		
		
	
		#
		#	Module accessor
		#
		def [] (mod)
			mod = mod.to_sym if mod.class == String
			@modules[mod].instance
		end

		attr_reader :modules
		attr_reader :communicator
		attr_reader :controller
		attr_accessor :logger
		
		
		#
		# Loads a module into a system
		#
		def load(dbSetting, theClass)
			if dbSetting.is_a?(ControllerDevice)
				load_hooks(ddbSetting, DeviceModule.new(self, dbSetting, theClass))
			elsif dbSetting.is_a?(ControllerHttpService)
				load_hooks(ddbSetting, ServiceModule.new(self, dbSetting, theClass))
			else # ControllerLogic
				load_hooks(ddbSetting, LogicModule.new(self, dbSetting, theClass))
			end
		end
		
		#
		# The system is ready to go
		#
		def start
			@communicator.start
		end
		
		#
		# Stops the current control system
		# 	Loops through the module instances.
		#
		def stop
			System.logger.info "stopping #{@controller.name}"
			@sys_lock.synchronize {
				if @controller.active
					@communicator.shutdown
					modules_unloaded = {}
					@modules.each_value do |mod|
						
						if modules_unloaded[mod] == nil
							modules_unloaded[mod] = :unloaded
							mod.unload
						end
						
					end
					@modules = {}	# Modules no longer referenced. Cleanup time!
					@logger.close if Rails.env.production?
					@logger = nil
				end
				
				@@god_lock.synchronize {
					@@controllers.delete(@controller.id)
					begin
						@controller.reload(:lock => true)
						@controller.active = false
					ensure
						@controller.save
					end
				}
			}
		end
		
		
		#
		# Log level changing on the fly
		#
		def log_level(level)
			@sys_lock.synchronize {
				@log_level = AutomateEm::get_log_level(level)
				if @controller.active
					@logger.level = @log_level
				end
			}
		end
		
	
		protected
	
	
		def load_hooks(device, mod)
			module_name = device.dependency.module_name
			count = 2	# 2 is correct
			
			#
			# Loads the modules and auto-names them (display_1, display_2)
			#	The first module of a type has two names (display and display_1 for example)
			#	Load order is controlled by the control_system model based on the ordinal
			#
			@sys_lock.synchronize {
				if not @modules[module_name.to_sym].nil?
					while @modules["#{module_name}_#{count}".to_sym].present?
						count += 1
					end
					module_name = "#{module_name}_#{count}"
				else
					@modules["#{module_name}_1".to_sym] = mod
				end
				@modules[module_name.to_sym] = mod
				
				#
				# Allow for system specific custom names
				#
				if !device.custom_name.nil?
					@modules[device.custom_name.to_sym] = mod
				end
			}
		end
		
		
		def initialize(controller, log_level)
			System.logger.info "starting #{controller.name}"
			
			@modules = {}	# controller modules	:name => module instance (device or logic)
			@communicator = AutomateEm::Communicator.new(self)
			@log_level = log_level
			@controller = controller
			@sys_lock = Mutex.new
			
			
			if Rails.env.production?
				@logger = Logger.new(Rails.root.join("log/system_#{@controller.id}.log").to_s, 10, 4194304)
			else
				@logger = Logger.new(STDOUT)
			end
			@logger.formatter = proc { |severity, datetime, progname, msg|
				"#{datetime.strftime("%d/%m/%Y @ %I:%M%p")} #{severity}: #{@controller.name} - #{msg}\n"
			}
		end
	end
end