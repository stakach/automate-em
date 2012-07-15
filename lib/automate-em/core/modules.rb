module AutomateEm
	class Modules
		@@modules = {}	# modules (dependency_id => module class)
		@@load_lock = Mutex.new
	
		def self.[] (dep_id)
			@@load_lock.synchronize {
				@@modules[dep_id]
			}
		end
		
		def self.lazy_load(dep)
			theClass = Modules[dep.id]
			theClass = Modules.load_module(dep) if theClass.nil?
			theClass
		end
	
		def self.load_module(dep)
			begin
				found = false
				file = "#{dep.classname.underscore}.rb"
				
				Rails.configuration.automate.module_paths.each do |path|
					if File.exists?("#{path}/#{file}")
						@@load_lock.synchronize {
							load "#{path}/#{file}"
						}
						found = true
						break
					end
				end
				
				if not found
					raise "File not found! (#{file})"
				end
				
				@@load_lock.synchronize {
					@@modules[dep.id] = dep.classname.constantize	# this is the return value
				}
			rescue Exception => e
				AutomateEm.print_error(System.logger, e, {
					:message => "device module #{dep.actual_name} error whilst loading.",
					:level => Logger::ERROR
				})
				
				return false
			end
		end
	end

	#
	# TODO:: Consider allowing different dependancies use the same connection
	# 	Means only the first will call received - others must use receive blocks
	#
	class DeviceModule
		@@instances = {}	# db id => @instance
		@@dbentry = {}		# db id => db instance
		@@devices = {}		# ip:port:udp => @instance
		@@lookup = {}		# @instance => db id array
		@@lookup_lock = Mutex.new
		
		def initialize(system, controllerDevice, theModule)
			@@lookup_lock.synchronize {
				if @@instances[controllerDevice.id].nil?
					@system = system
					@device = controllerDevice.id
					@@dbentry[controllerDevice.id] = controllerDevice
				end
			}
			instantiate_module(controllerDevice, theModule)
		end
		
		
		def unload	# should never be called on the reactor thread so no need to defer
			
			@instance.base.shutdown(@system)
			
			@@lookup_lock.synchronize {
				db = @@lookup[@instance].delete(@device)
				@@instances.delete(db)
				db = @@dbentry.delete(db)
				dev = "#{db.ip}:#{db.port}:#{db.udp}"
				
				if @@lookup[@instance].empty?
					@@lookup.delete(@instance)
					if db.udp
						$datagramServer.remove_device(db)
					end
					@@devices.delete(dev)
				end
			}
		end
		

		def self.lookup(instance)
			@@lookup_lock.synchronize {
				return @@dbentry[@@lookup[instance][0]]
			}
		end
		
		def self.instance_of(db_id)
			@@lookup_lock.synchronize {
				return @@instances[db_id]
			}
		end
		
		
		attr_reader :instance
		
		
		protected
	
	
		def instantiate_module(controllerDevice, theModule)
			baselookup = "#{controllerDevice.ip}:#{controllerDevice.port}:#{controllerDevice.udp}"
			
			@@lookup_lock.lock
			if @@devices[baselookup].nil?
				
				#
				# Instance of a user module
				#
				begin
					@instance = theModule.new(controllerDevice.tls, controllerDevice.makebreak)
					@instance.join_system(@system)
					@@instances[@device] = @instance
					@@devices[baselookup] = @instance
					@@lookup[@instance] = [@device]
				ensure
					@@lookup_lock.unlock	#UNLOCK!! so we can lookup settings in on_load
				end
				
				devBase = nil
				
				loaded = Proc.new {
					EM.defer do
						if @instance.respond_to?(:on_load)
							begin
								@instance.on_load
							rescue => e
								AutomateEm.print_error(System.logger, e, {
									:message => "device module #{@instance.class} error whilst calling: on_load",
									:level => Logger::ERROR
								})
							ensure
								ActiveRecord::Base.clear_active_connections!
							end
						end
						
						if controllerDevice.udp
							EM.schedule do
								devBase.call_connected	# UDP is stateless (always connected)
							end
						end
					end
				}
					
				if !controllerDevice.udp
					res = ResolverJob.new(controllerDevice.ip)
					res.callback {|ip|
						EM.connect ip, controllerDevice.port, Device::Base, @instance, false # controllerDevice.udp
						loaded.call
					}
					res.errback {|error|
						EM.defer do
							System.logger.info error.message + " connecting to #{controllerDevice.dependency.actual_name} @ #{controllerDevice.ip} in #{controllerDevice.control_system.name}"
						end
						EM.connect "127.0.0.1", 10, Device::Base, @instance, false	# Connect to a nothing port until the device name is found or updated
						loaded.call
					}
				else
					#
					# Load UDP device here
					#	Create UDP base
					#	Add device to server
					# => TODO::test!!
					#	Call connected
					#
					devBase = DatagramBase.new(@instance, true)
					$datagramServer.add_device(controllerDevice, devBase)
					loaded.call
				end
					
					#@@devices[baselookup] = Modules.loading	# set in device_connection (see todo above)
			else
				#
				# add parent may lock at this point!
				#
				begin
					@instance = @@devices[baselookup]
					@@lookup[@instance] << @device
					@@instances[@device] = @instance
					EM.defer do
						@instance.join_system(@system)
					end
				ensure
					@@lookup_lock.unlock	#UNLOCK!!
				end
			end
		end
	end
	
	
	class ServiceModule
		@@instances = {}	# db id => @instance
		@@dbentry = {}		# db id => db instance
		@@services = {}		# uri => @instance
		@@lookup = {}		# @instance => db id array
		@@lookup_lock = Mutex.new
		
		def initialize(system, controllerService, theModule)
			@@lookup_lock.synchronize {
				if @@instances[controllerService.id].nil?
					@system = system
					@service = controllerService.id
					@@dbentry[controllerService.id] = controllerService
				end
			}
			instantiate_module(controllerService, theModule)
		end
		
		
		def unload	# should never be called on the reactor thread so no need to defer
			
			@instance.base.shutdown(@system)
			
			@@lookup_lock.synchronize {
				db = @@lookup[@instance].delete(@service)
				@@instances.delete(db)
				db = @@dbentry.delete(db)
				
				if @@lookup[@instance].empty?
					@@lookup.delete(@instance)
					@@services.delete(db.uri)
				end
			}
		end
		

		def self.lookup(instance)
			@@lookup_lock.synchronize {
				return @@dbentry[@@lookup[instance][0]]
			}
		end
		
		def self.instance_of(db_id)
			@@lookup_lock.synchronize {
				return @@instances[db_id]
			}
		end
		
		
		attr_reader :instance
		
		
		protected
	
	
		def instantiate_module(controllerService, theModule)			
			@@lookup_lock.lock
			if @@services[controllerService.uri].nil?
				begin
					#
					# Instance of a user module
					#
					@instance = theModule.new
					@instance.join_system(@system)
					@@instances[@service] = @instance
					@@services[controllerService.uri] = @instance
					@@lookup[@instance] = [@service]
				ensure
					@@lookup_lock.unlock #UNLOCK
				end
				
				HttpService.new(@instance, controllerService)
				
				
				if @instance.respond_to?(:on_load)
					begin
						@instance.on_load
					rescue => e
						AutomateEm.print_error(System.logger, e, {
							:message => "service module #{@instance.class} error whilst calling: on_load",
							:level => Logger::ERROR
						})
					ensure
						ActiveRecord::Base.clear_active_connections!
					end
				end
			else
				#
				# add parent may lock at this point!
				#
				@instance = @@services[controllerService.uri]
				@@lookup[@instance] << @service
				@@instances[@service] = @instance
				EM.defer do
					@instance.join_system(@system)
				end
				@@lookup_lock.unlock #UNLOCK
			end
		end
	end


	class LogicModule
		@@instances = {}	# id => @instance
		@@lookup = {}		# @instance => DB Record
		@@lookup_lock = Mutex.new
		

		def initialize(system, controllerLogic, theModule)
			@@lookup_lock.synchronize {
				if @@instances[controllerLogic.id].nil?
					instantiate_module(controllerLogic, system, theModule)
				end
			}
			if @instance.respond_to?(:on_load)
				begin
					@instance.on_load
				rescue => e
					AutomateEm.print_error(System.logger, e, {
						:message => "logic module #{@instance.class} error whilst calling: on_load",
						:level => Logger::ERROR
					})
				ensure
					ActiveRecord::Base.clear_active_connections!
				end
			end
		end
		
		def unload
			if @instance.respond_to?(:on_unload)
				begin
					@instance.on_unload
				rescue => e
					AutomateEm.print_error(System.logger, e, {
						:message => "logic module #{@instance.class} error whilst calling: on_unload",
						:level => Logger::ERROR
					})
				ensure
					ActiveRecord::Base.clear_active_connections!
				end
			end
			
			@instance.clear_active_timers
			
			@@lookup_lock.synchronize {
				db = @@lookup.delete(@instance)
				@@instances.delete(db.id)
			}
		end
		
		def self.lookup(instance)
			@@lookup_lock.synchronize {
				return @@lookup[instance]
			}
		end
		
		def self.instance_of(db_id)
			@@lookup_lock.synchronize {
				return @@instances[db_id]
			}
		end
		
		attr_reader :instance


		protected


		def instantiate_module(controllerLogic, system, theModule)
			@instance = theModule.new(system)
			@@instances[controllerLogic.id] = @instance
			@@lookup[@instance] = controllerLogic
		end
	end
end