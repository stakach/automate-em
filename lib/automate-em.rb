

#
# TODO:: Use autoload here to avoid loading these unless control is running!
#

#
# STD LIB
#
require 'observer'
require 'yaml'
require 'thread'
require 'monitor'
require 'Socket'	# for DNS lookups 
require 'Logger'


#
# Gems
#
require 'rubygems'
require 'eventmachine'
require 'em-priority-queue'
require 'em-http'
require 'rufus/scheduler'
require 'ipaddress'


#
# Library Files
#
require 'automate-em/constants.rb'
require 'automate-em/utilities.rb'
require 'automate-em/status.rb'

require 'automate-em/core/resolver_pool.rb'
require 'automate-em/core/modules.rb'
require 'automate-em/core/communicator.rb'
require 'automate-em/core/system.rb'

require 'automate-em/device/device.rb'
require 'automate-em/device/device_connection.rb'
require 'automate-em/device/datagram_server.rb'
require 'automate-em/device/tcp_control.rb'

require 'automate-em/service/service.rb'
require 'automate-em/service/http_service.rb'

require 'automate-em/logic/logic.rb'

require 'automate-em/interfaces/html5.rb'


module AutomateEm
	
	
	def self.load_paths= (paths)
		@@load_paths = ([] << paths) # TODO:: this doesn't work
	end
	
	
	def self.scheduler
		@@scheduler
	end
	
	
	def self.resolver
		@@resolver
	end
	
	
	def self.get_log_level(level)
		if level.nil?
			return Logger::INFO
		else
			return case level.downcase.to_sym
				when :debug
					Logger::DEBUG
				when :warn
					Logger::WARN
				when :error
					Logger::ERROR
				else
					Logger::INFO
			end
		end
	end
	
	
	def self.boot
		
		#
		# System level logger
		#
		if Rails.env.production?
			System.logger = Logger.new(Rails.root.join('log/system.log').to_s, 10, 4194304)
		else
			System.logger = Logger.new(STDOUT)
		end
		System.logger.formatter = proc { |severity, datetime, progname, msg|
			"#{datetime.strftime("%d/%m/%Y @ %I:%M%p")} #{severity}: #{System} - #{msg}\n"
		}
		
		@@resolver = ResolverPool.new
		
		EventMachine.run do
			#
			# Enable the scheduling system
			#
			@@scheduler = Rufus::Scheduler.start_new
			
			EM.defer do
				System.logger.debug "Started with #{EM.get_max_timers} timers avaliable"
				System.logger.debug "Started with #{EM.threadpool_size} threads in pool"
			end
			
			#
			# Start the UDP server
			#
			EM.open_datagram_socket "0.0.0.0", 0, DatagramServer
			
			#
			# Load the system based on the database
			#
			ControlSystem.all.each do |controller|
				EM.defer do
					begin
						System.logger.debug "Booting #{controller.name}"
						System.new_system(controller, Rails.configuration.automate.log_level)
					rescue => e
						AutomateEm.print_error(AutomateEm::System.logger, e, {
							:message => "Error during boot",
							:level => Logger::FATAL
						})
						EventMachine::stop_event_loop
					end
				end
			end
			
			#
			# Emit connection counts for logging
			#
			@@scheduler.every '10m' do
				System.logger.info "There are #{EM.connection_count} connections to this server"
			end
			
			#
			# We should AutoLoad the interfaces as plugins rather than having them in the core
			#
			EM.add_timer(20) do
				System.start_websockets
			end
		end
	
end
