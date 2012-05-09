
desc 'Start the automation server'
task :automate => :environment do
	AutomateEm.boot
end
