require 'uri'


class ActionController::Base
	alias_method :old_verify, :verified_request?
	
	protected
	
	def verified_request?
		old_verify || form_authenticity_token == request.headers['X_XSRF_TOKEN']
	end
	
	def cors_set_access_control_headers
		headers['Access-Control-Allow-Origin'] = '*'
		headers['Access-Control-Allow-Methods'] = 'POST, GET, PUT, DELETE, OPTIONS'
		headers['Access-Control-Allow-Headers'] = '*, X-Requested-With, X-Prototype-Version, X-CSRF-Token, X_XSRF_TOKEN, Content-Type'
		headers['Access-Control-Max-Age'] = "1728000"
	end

	def set_csrf_cookie_for_ng
		cookies['XSRF-TOKEN'] = form_authenticity_token if protect_against_forgery?
	end
	
	skip_before_filter :verify_authenticity_token, :only => :options	# do not use CSRF for CORS options
	before_filter :cors_set_access_control_headers
	after_filter  :set_csrf_cookie_for_ng, :except => :options
end


class TokensController < ActionController::Base
	
	protect_from_forgery
	
	
	before_filter :auth_user, :only => [:accept]
	layout nil


	def authenticate	# Allowed through by application controller
		#
		# Auth(gen)
		# check the system matches (set user and system in session)
		# respond with success
		#
		dev = TrustedDevice.try_to_login(params[:key], true)	# true means gen the next key
		if params[:system].present? && dev.present? && params[:system].to_i == dev.control_system_id
			session[:token] = dev.user_id
			session[:system] = dev.control_system_id
			session[:key] = params[:key]
			cookies.permanent[:next_key] = {:value => dev.next_key, :path => URI.parse(request.referer).path}

			render :nothing => true	# success!
		else
			render :nothing => true, :status => :forbidden	# 403
		end
	end


	def accept
		dev = TrustedDevice.where('user_id = ? AND control_system_id = ? AND one_time_key = ? AND (expires IS NULL OR expires > ?)', 
				session[:token], session[:system], session[:key], Time.now).first

		if dev.present?
			dev.accept_key
			render :nothing => true	# success!
		else
			render :nothing => true, :status => :forbidden	# 403
		end
	end


	#
	# Build a new session for the interface if the existing one has expired
	#	This maintains the csrf security
	#	We don't want to reset the session if a valid user is already authenticated either
	#
	def new
		reset_session unless session[:user].present?

		render :text => form_authenticity_token
	end


	def create
		#
		# Application controller ensures we are logged in as real user
		# Ensure the user can access the control system requested (the control system does this too)
		# Generate key, populate the session
		#
		user = nil
		if params[:user].present?
			user = User.try_to_login(params[:user][:name]], params[:user][:password], AuthSource.where('name = ?', params[:user][:domain]).first)
		elsif session[:user].present?
			user = User.find(session[:user]) # We have to be authed to get here
		end
		sys = user.control_systems.where('control_systems.id = ?', params[:system]).first unless user.nil?
		if user.present? && sys.present?

			dev = TrustedDevice.new
			dev.reason = params[:trusted_device][:reason]
			dev.user = user
			dev.control_system = sys
			dev.save

			if !dev.new_record?
				cookies.permanent[:next_key] = {:value => dev.one_time_key, :path => URI.parse(request.referer).path}
				render :json => {:next_key => dev.one_time_key}	# success!
			else
				render :json => dev.errors.messages, :status => :not_acceptable	# 406
			end
		else
			if user.present?
				render :json => {:control => 'could not find the system selected'}, :status => :forbidden	# 403
			else
				render :json => {:you => 'are not authorised'}, :status => :forbidden	# 403
			end
		end
	end


	def servers
		render :json => Server.where(:online => true).all
	end
	
	
	def options 
		render :text => '', :content_type => 'text/plain'
	end


	protected
	

	


	def auth_user
		redirect_to root_path unless session[:user].present? || session[:token].present?
	end
	
end
