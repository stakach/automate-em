class AutomateEm::ModuleGenerator < Rails::Generators::NamedBase
	#source_root File.expand_path('../templates', __FILE__)
	
		def create_module_file
		
		param = file_name
		param = param.split(/\/|\\/)
		param.map! {|item| item.downcase.gsub!(/[-\s]/, '_')}
		
		name = param.pop
		path = param.join('/')
		
		scope = []
		text = ""
		param.map! {|item|
			item = item.classify
			scope << item
			text += "module #{scope.join('::')}; end\n"
			item
		}
		scope = param.join('::')
		
		
		create_file "#{path}/#{name}.rb" do
			type = ask("What type of module (device, service, logic) will this be?")
			
			text += <<-FILE
class #{scope}::#{name.classify} < AutomateEm::#{type.downcase.classify}
	def on_load
	end
	
	def on_unload
	end
	
	def on_update
	end
end			
			FILE
			
			text
		end
		
	end
end
