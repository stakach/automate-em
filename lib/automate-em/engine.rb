module AutomateEm
	class Engine < ::Rails::Engine
		engine_name :automate
		
		
		rake_tasks do
			load "tasks/automate-em_tasks.rake"
		end
		
		#
		# Define the application configuration
		#
		config.before_initialize do |app|						# Rails.configuration
			app.config.automate = ActiveSupport::OrderedOptions.new
			app.config.automate.module_paths = []
			app.config.automate.log_level = Logger::INFO
		end
		
		#
		# Discover the possible module location paths after initialisation is complete
		#
		config.after_initialize do |app|
			
			app.config.assets.paths.each do |path|
				Pathname.new(path).ascend do |v|
					if ['app', 'vendor'].include?(v.basename.to_s)
						app.config.automate.module_paths << "#{v.to_s}/modules"
						break
					end
				end
			end
			
			app.config.automate.module_paths.uniq!
		end
	end
end
