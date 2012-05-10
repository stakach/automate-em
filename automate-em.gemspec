$:.push File.expand_path("../lib", __FILE__)

# Maintain your gem's version:
require "automate-em/version"

# Describe your gem and declare its dependencies:
Gem::Specification.new do |s|
  s.name        = "automate-em"
  s.version     = AutomateEm::VERSION
  s.authors     = ["Stephen von Takach"]
  s.email       = ["steve@advancedcontrol.com.au"]
  s.homepage    = "http://advancedcontrol.com.au/"
  s.summary     = "A framework for building automation."
  s.description = "A framework for building automation."

  s.files = Dir["{app,config,db,lib}/**/*"] + ["LGPL3-LICENSE", "Rakefile", "README.textile"]
  s.test_files = Dir["test/**/*"]

  s.add_dependency "rails", ">= 3.2.0"
  s.add_dependency "eventmachine", ">= 1.0.0.beta.3"
  s.add_dependency "em-priority-queue"
  s.add_dependency "em-http-request"
  s.add_dependency "rufus-scheduler"
  s.add_dependency "ipaddress"
  s.add_dependency "em-websocket"
  s.add_dependency "atomic"
  s.add_dependency "simple_oauth"
  s.add_dependency "yajl-ruby"

  s.add_development_dependency "sqlite3"
end
