require 'em-websocket'
require 'json'


#
# This system was designed based on the following articles
#			https://gist.github.com/299789
#			http://blog.new-bamboo.co.uk/2010/2/10/json-event-based-convention-websockets
#


class HTML5Monitor
	@@clients = {}
	@@special_events = {
		"system" => :system,
		"authenticate" => :authenticate,
		"ls" => :ls,
		"ping" => :ping
	}
	@@special_commands = {
		"register" => :register,
		"unregister" => :unregister
	}

	def self.register(id)
		@@clients[id] = HTML5Monitor.new(id)
	end
	
	def self.unregister(id)
		client = @@clients.delete(id)
		
		#EM.defer do
			begin
				client.disconnected
				AutomateEm::System.logger.debug "There are now #{HTML5Monitor.count} HTML5 clients connected"
			rescue => e
				AutomateEm.print_error(AutomateEm::System.logger, e, {
					:message => "in html5.rb, onclose : unregistering client did not exist (we may have been shutting down)",
					:level => Logger::ERROR
				})
			end
		#end
	end
	
	def self.count
		return @@clients.length
	end
	
	def self.receive(id, data)
		client = @@clients[id]
		
		#EM.defer do
			begin
				client.receive(data)
			rescue Exception => e
				AutomateEm.print_error(AutomateEm::System.logger, e, {
					:message => "in html5.rb, onmessage : client did not exist (we may have been shutting down)",
					:level => Logger::ERROR
				})
			ensure
				ActiveRecord::Base.clear_active_connections!	# Clear any unused connections
			end
		#end
	end
	
	
	def initialize(socket)
		@data_lock = Mutex.new
		
		#
		# Must authenticate before any system details will be sent
		#
		@socket = socket
		@system = nil
		@user = nil
		
		
		@socket.send(JSON.generate({:event => "authenticate", :data => []}))
	rescue
		#
		# TODO:: start a schedule here that sends a ping to the browser every so often
		#
	end
	
	
	#
	#
	# Instance methods:
	#
	#
	def try_auth(data = nil)
		
		return false if @ignoreAuth

		if !!@user
			if data.nil?
				return true
			else
				@user = nil
				return try_auth(data)
			end
		else
			if !data.nil? && data.class == Array
				if data.length == 1	# one time key
					@user = TrustedDevice.try_to_login(data[0])
				elsif data.length == 3
											#user, password, auth_source
					source = AuthSource.where("name = ?", data[2]).first
					@user = User.try_to_login(data[0], data[1], source)
				end
				
				return try_auth	# no data
			end
			
			#
			# Prevent DOS/brute force Attacks
			#
			@ignoreAuth = true
			EM.add_timer(2) do
				begin
					do_send_authenticate
				rescue
				ensure
					@ignoreAuth = false
				end
			end
		end
		return false
	end

	def do_send_authenticate
		begin
			@socket.send(JSON.generate({:event => "authenticate", :data => []}))
		rescue
		ensure
			@ignoreAuth = false
		end
	end
	
	def send_system
		return if @ignoreSys	
		@ignoreSys = true
		
		EM.add_timer(2) do
			begin
				do_send_system
			ensure
				@ignoreSys = false
			end
		end
	end

	def do_send_system
		begin
			@socket.send(JSON.generate({:event => "system", :data => []}))
		rescue
		ensure
			@ignoreSys = false
		end
	end
	
	def disconnected
		@data_lock.synchronize {
			@system.disconnected(self) if (!!@system)	# System could be nil or false
		}
	end
	
	def receive(data)
		data = JSON.parse(data, {:symbolize_names => true})
		return unless data[:command].class == String
		data[:data] = [] unless data[:data].class == Array

		@data_lock.synchronize {
			#
			# Ensure authenticated
			#
			if data[:command] == "authenticate"
				return unless try_auth(data[:data])
				send_system
				return
			else
				return unless (try_auth || data[:command] == "ping")
			end
			
			#
			# Ensure system is selected
			#	If a command is sent out of order
			#
			if @system.nil? && !@@special_events.has_key?(data[:command])
				send_system
				return
			end
			
			if @@special_events.has_key?(data[:command])		# system, auth, ls
				case @@special_events[data[:command]]
					when :system
						@system.disconnected(self) unless @system.nil?
						@system = nil
						@system = AutomateEm::Communicator.select(@user, self, data[:data][0]) unless data[:data].empty?
						if @system.nil?
							send_system
						elsif @system == false	# System offline
							EM.schedule do
								begin
									@socket.send(JSON.generate({:event => "offline", :data => []}))
									shutdown
								rescue
								end
							end
						else
							EM.schedule do
								begin
									@socket.send(JSON.generate({:event => "ready", :data => []}))
								rescue
								end
							end
						end
					when :ping
						EM.schedule do
							begin
								@socket.send(JSON.generate({:event => "pong", :data => []}))
							rescue
							end
						end
					when :ls
						systems = AutomateEm::Communicator.system_list(@user)
						EM.schedule do
							begin
								@socket.send(JSON.generate({:event => "ls", :data => systems}))
							rescue
							end
						end
				end
			elsif @@special_commands.has_key?(data[:command])	# reg, unreg
				array = data[:data]
				array.insert(0, self)
				@system.public_send(data[:command], *array)
			else									# All other commands
				command = data[:command].split('.')
				if command.length == 2
					@system.send_command(command[0], command[1], *data[:data])
				else
					AutomateEm::System.logger.info "-- in html5.rb, receive : invalid command received - #{data[:command]} --"
				end
			end
		}
	rescue => e
		logger = nil
		@data_lock.synchronize {
			logger = @system.nil? ? AutomateEm::System.logger : @system.logger
		}
		AutomateEm.print_error(logger, e, {
			:message => "in html5.rb, receive : probably malformed JSON data",
			:level => Logger::ERROR
		})
		shutdown
	end
	
	def shutdown
		EM.schedule do
			begin
				@socket.close_websocket
			rescue
			end
		end
	end
	
	def notify(mod_sym, stat_sym, data)
		#
		# This should be re-entrant? So no need to protect
		#
		@system.logger.debug "#{mod_sym}.#{stat_sym} sent #{data.inspect}"
		EM.schedule do
			begin
				@socket.send(JSON.generate({"event" => "#{mod_sym}.#{stat_sym}", "data" => data}))
			rescue
			end
		end
	end
end


module AutomateEm
	class System
		@@socket_server = nil
		def self.start_websockets
			EM.schedule do
				if @@socket_server.nil?
					@@socket_server = EventMachine::WebSocket.start(:host => "0.0.0.0", :port => 81) do |socket| # , :debug => true
						socket.onopen {
							#
							# This socket represents a connected device
							#
							HTML5Monitor.register(socket)
						}
						
						socket.onmessage { |data|
							#
							# Attach socket here to system
							#	then process commands
							#
							HTML5Monitor.receive(socket, data)
						}
				
						socket.onclose {
							HTML5Monitor.unregister(socket)
						}
						
						socket.onerror { |error|
							if !error.kind_of?(EM::WebSocket::WebSocketError)
								EM.defer do
									AutomateEm.print_error(AutomateEm::System.logger, error, {
										:message => "in html5.rb, onerror : issue with websocket data",
										:level => Logger::ERROR
									})
								end
							else
								EM.defer do
									AutomateEm::System.logger.info "in html5.rb, onerror : invalid handshake received - #{error.inspect}"
								end
							end
						}
					end
				
				end
			end
			EM.defer do
				AutomateEm::System.logger.info 'running HTML5 socket server on port 81'
			end
		end
		
		def self.stop_websockets
			EM.schedule do
				begin
					EventMachine::stop_server(@@socket_server) unless @@socket_server.nil?
					@@socket_server = nil
				rescue
				end
			end
		end
	end
end
