Rails.application.routes.draw do
	
	#
	# TODO:: Namespace this
	#
	resources :tokens do
		post	:authenticate,	:on => :collection
		post	:accept,		:on => :collection
		get		:servers,		:on => :collection
	end
	
	match '/*path' => 'tokens#options', :via => :options

end
