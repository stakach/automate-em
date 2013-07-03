class ControlSystem < ActiveRecord::Base
	has_many :devices, -> {order: 'priority ASC'},	:class_name => "ControllerDevice",	:dependent => :destroy
	has_many :logics, -> {order: 'priority ASC'},	:class_name => "ControllerLogic",	:dependent => :destroy
	has_many :services, -> {order: 'priority ASC'},	:class_name => "ControllerHttpService",	:dependent => :destroy
	
	has_many :controller_zones,		:dependent => :destroy
	has_many :zones,				:through => :controller_zones
	has_many :user_zones,			:through => :zones
	has_many :groups,				:through => :user_zones
	has_many :users,				:through => :groups
	
	has_many :trusted_devices,		:dependent => :destroy
	
	
	protected
	
	
	validates_presence_of :name
	validates_uniqueness_of :name
end
