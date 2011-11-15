# Requests to the Resolve controller are OpenURLs.
# There is one exception: Instead of an OpenURL, you can include the
# parameter umlaut.request_id=[some id] to hook up to a pre-existing
# umlaut request (that presumably was an OpenURL). 

class ResolveController < ApplicationController
  before_filter :init_processing
  # Init processing will look at this list, and for actions mentioned,
  # will not create a @user_request if an existing one can't be found.
  # Used for actions meant only to deal with existing requests. 
  @@no_create_request_actions = ['background_update']
  after_filter :save_request
  
  # Take layout from config, default to resolve_basic.rhtml layout. 
  layout AppConfig.param("resolve_layout", "resolve_basic").to_s, 
         :except => [:partial_html_sections]
  #require 'json/lexer'

  # If a background service was started more than 30 seconds
  # ago and isn't finished, we assume it died. This value
  # can be set in app config variable background_service_timeout.

  class << self; attr_accessor :background_service_timeout end
  @background_service_timeout = AppConfig.param("background_service_timeout", 30.seconds)

  
  # If a service has status FailedTemporary, and it's older than a
  # certain value, it will be re-queued in #serviceDispatch.
  # This value defaults to 10 times background_service_timeout,
  # but can be set in app config variable requeue_failedtemporary_services
  # If you set it too low, you can wind up with a request that never completes,
  # as it constantly re-queues a service which constantly fails.
  class << self; attr_accessor :requeue_failedtemporary_services end
  @requeue_failedtemporary_services = AppConfig.param("requeue_failedtemporary_services", background_service_timeout * 10)
  
  
  
  # Retrives or sets up the relevant Umlaut Request, and returns it. 
  def init_processing
    # intentionally trigger creation of session if it didn't already exist
    # because we need to track session ID for caching. Can't find any
    # way to force session creation without setting a value in session,
    # so we do this weird one. 
    session[nil] = nil
    options = {}
    if (  @@no_create_request_actions.include?(params[:action])  )
      options[:allow_create] = false
    end
    @user_request ||= Request.new_request(params, session, request, options )

    # If we chose not to create a request and still don't have one, bale out.
    return unless @user_request
    
    # Ip may be simulated with req.ip in context object, or may be
    # actual, request figured it out for us. 
    @collection = Collection.new(@user_request, session, params["umlaut.institution"])      
    @user_request.save!
    # Set 'timed out' background services to dead if neccesary. 
    @user_request.dispatched_services.each do | ds |
        if ( (ds.status == DispatchedService::InProgress ||
              ds.status == DispatchedService::Queued ) &&
              (Time.now - ds.updated_at) > self.class.background_service_timeout)

              ds.store_exception( Exception.new("background service timed out (took longer than #{self.class.background_service_timeout} to run); thread assumed dead.")) unless ds.exception_info
              # Fail it temporary, it'll be run again. 
              ds.status = DispatchedService::FailedTemporary
              ds.save!
              logger.warn("Background service timed out, thread assumed dead. #{@user_request.id} / #{ds.service.service_id}")
        end
    end
    
    return @user_request
  end

  require 'CronTab'
  # Expire expired service_responses if neccesary.
  # See app config params 'response_expire_interval' and
  # 'response_expire_crontab_format'.     
  def expire_old_responses
    
    expire_interval = AppConfig.param('response_expire_interval')
    crontab_format = AppConfig.param('response_expire_crontab_format')

    unless (expire_interval || crontab_format)      
      # Not needed, nothing to expire
      return nil
    end
    
    @user_request.dispatched_services.each do |ds|

      now = Time.now
      
      expired_interval = expire_interval && 
        (now - ds.created_at > expire_interval)
      expired_crontab = crontab_format && 
        (now > CronTab.new(crontab_format).nexttime(ds.created_at))
      
      # Only expire completed ones, don't expire in-progress ones! 
      if (ds.completed && ( expired_interval || expired_crontab ))
          
          # Need to expire. Delete all the service responses, and
          # the DispatchedService record, and service will be automatically
          # run again. 
          
          serv_id = ds.service.service_id
          expired_responses = @user_request.service_types.each do |st|
            
            if st.service_response.service.service_id == serv_id
              @user_request.service_types.delete(st)
              st.service_response.destroy
              st.destroy
            end
          end
          @user_request.dispatched_services.delete(ds)
          ds.destroy
      end
    end
  end

  def save_request
    @user_request.save!
  end
 		
  def index
    self.service_dispatch()

    # check for menu skipping configuration. link is a ServiceType object
    link = should_skip_menu
    if ( ! link.nil? )                   
      
      redirect_to url_for(:controller => "link_router",
                   :action => "index",
                   :id => link.id )            
    else
      # Render configed view, if configed, or default view if not. 
      view = AppConfig.param("resolve_view", nil)      
      render view
    end

  end

  # inputs an OpenURL request into the system and stores it, but does
  # NOT actually dispatch services to provide a response. Will usually 
  # be called by software, not a human browser. Sometimes
  # it's useful to do this as a first step before redirecting the user
  # to the actual resolve action for the supplied request--for instance,
  # when the OpenURL metadata comes in a POST and can't be redirected. 
  def register_request
    # init before filter already took care of setting up the request.
    @user_request.save!

    # Return data in headers allowing client to redirect user
    # to view actual response. 
    headers["x-umlaut-request_id"] = @user_request.id
    headers["x-umlaut-resolve_url"] = url_for( :controller => 'resolve', 'umlaut.request_id'.to_sym => @user_request.id )
    headers["x-umlaut-permalink_url"] = permalink_url( request, @user_request )

    # Return empty body. Once we have the xml response done,
    # this really ought to return an xml response, but with
    # no service responses yet available.
    render(:nothing => true)
  end

  # Useful for developers, generate a coins. Start from
  # search/journals?umlaut.display_coins=true
  # or search/books?umlaut.display_coins=true
  def display_coins

  end
  
  

  # Action called by AJAXy thing to update resolve menu with
  # new stuff that got done in the background. 
  def background_update
    unless (@user_request)
      # Couldn't find an existing request? We can do nothing.
      raise Exception.new("background_update could not find an existing request to pull updates from, umlaut.request_id #{params["umlaut.request_id"]}")
    end
  end

  # Display a non-javascript background service status page--or
  # redirect back to index if we're done.
  def background_status

    unless ( @user_request.any_services_in_progress? )
      
      # Just redirect to ordinary index, no need to show progress status.
      # Include request.id, but also context object kev. 
      
      params_hash = 
         {:controller=>"resolve",
          :action=>'index', 
          'umlaut.skip_resolve_menu'.to_sym => params['umlaut.skip_resolve_menu'],
          'umlaut.request_id'.to_sym => @user_request.id }
      
      url = url_for_with_co( params_hash, @user_request.to_context_object )
      
      redirect_to( url )
    else
      # If we fall through, we'll show the background_status view, a non-js
      # meta-refresh update on progress of background services.
      # Your layout should respect this instance var--it will if it uses
      # the resolve_head_content partial, which it should.
      @meta_refresh_self = 5  
    end
  end

  # This action is for external callers. An external caller _could_ get
  # data as xml or json or whatever. But Umlaut already knows how to render
  # it. What if the external caller wants the rendered content, but in
  # discrete letter packets, a packet of HTML for each ServiceTypeValue?
  # This does that, and also let's the caller know if background
  # services are still running and should be refreshed, and gives
  # the caller a URL to refresh from if neccesary.   
  
  def partial_html_sections
    # Tell our application_helper#url_for to generate urls with hostname
    @generate_urls_with_host = true

    # Force background status to be the spinner--default js way of putting
    # spinner in does not generally work through ajax techniques.
    @force_bg_progress_spinner = true

    # Mark that we're doing a partial generation, because it might
    # matter later. 
    @generating_embed_partials = true
    
    @partial_html_sections = SectionRenderer.partial_html_sections.clone    
    
    # Run the request if neccesary. 
    self.service_dispatch()
    @user_request.save!

    self.api_render()
    
  end
  
  def api

    # Run the request if neccesary. 
    self.service_dispatch()
    @user_request.save!

    api_render()
    
  end  


    
  def rescue_action_in_public(exception)  
    render(:template => "error/resolve_error", :status => 500, :layout => AppConfig.param("resolve_layout", "resolve_basic")) 
  end  

  protected

  # Based on app config and context, should we skip the resolve
  # menu and deliver a 'direct' link? Returns nil if menu
  # should be displayed, or the ServiceType join object
  # that should be directly linked to. 
  def should_skip_menu
    # From usabilty test, do NOT skip if coming from A-Z list/journal lookup.
    # First, is it over-ridden in url?
    if ( params['umlaut.skip_resolve_menu'] == 'false')
      return nil
    elsif ( params['umlaut.skip_resolve_menu_for_type'] )      
      skip = {:service_types => params['umlaut.skip_resolve_menu_for_type'].split(",") }
    end
    
    # Otherwise if not from url, load from app config
    skip  ||= AppConfig.param('skip_resolve_menu', false) if skip.nil?

    

    if (skip.kind_of?( FalseClass ))
      # nope
      return nil
    end

    return_value = nil
    if (skip.kind_of?(Hash) )
      # excluded rfr_ids?
      exclude_rfr_ids = skip[:excluded_rfr_ids]
      rfr_id = @user_request.referrer && @user_request.referrer.identifier 
      return nil if exclude_rfr_ids != nil && exclude_rfr_ids.find {|i| i == rfr_id}

      # Services to skip for?
      skip[:service_types].each do | service |
        service = ServiceTypeValue[service] unless service.kind_of?(ServiceTypeValue)  

        candidates = 
        @user_request.service_types.find(:all, 
          :conditions => ["service_type_value_name = ?", service.name])
        
        return_value = candidates.first 
        
      end

      # But wait, make sure it's included in :services if present.
      if (return_value && skip[:services] )
        return_value = nil unless skip[:services].include?( return_value.service_response.service.service_id )
      end
    elsif (skip.kind_of?(Proc ))
      return_value = skip.call( :request => @user_request )
      
    else
      logger.error( "Unexpected value in app config 'skip_resolve_menu'; assuming false." )
    end

    
    return return_value;    
  end

  


  # Uses an "umlaut.response_format" param to return either
  # XML or JSON(p).  Is called from an action that has a standardly rendered
  # Rails template that delivers XML.  Will convert that standardly rendered
  # template output to json using built in converters if needed.  
  def api_render    
    # Format?
    request.format = "xml" if request.format.html? # weird hack to support legacy behavior, with xml as default
    if params["umlaut.response_format"] == "jsonp"
      request.format = "json"
      params["umlaut.jsonp"] ||= "umlautLoaded" 
    elsif params["umlaut.response_format"]
      request.format = params["umlaut.response_format"]
    end
        
    
    respond_to do |format|
      format.xml do         
        render(:layout => false)
      end
      
      format.json do        
        # get the xml in a string
        xml_str = 
          with_format(:xml) do
            render_to_string(:layout=>false)
          end
        # convert to hash. For some reason the ActionView::OutputBuffer
        # we actually have (which looks like a String but isn't exactly)
        # can't be converted to a hash, we need to really force String
        # with #to_str
        data_as_hash = Hash.from_xml( xml_str.to_str )
        # And conver to json. Ta-da!
        json_str = data_as_hash.to_json
  
        # Handle jsonp, deliver JSON inside a javascript function call,
        # with function name specified in parameters. 
        render(:json => json_str, :callback => params["umlaut.jsonp"] )      
      end    
    end
  end

  def service_dispatch()
    expire_old_responses()

    # Register ALL bg/fg services as 'queued' in part to make
    # sure we don't run them twice as a result of a browser refresh
    # or AJAX request. We want to make sure anything ALREADY
    # marked as 'queued' is not re-run, and anything we're about to run
    # gets marked as queued.        
    queued_service_ids = @user_request.queue_all_regular_services(@collection, :requeue_temp_fails => true).collect {|s| s.service_id }
    
    # Foreground services
    (0..9).each do | priority |      
      services = @collection.instantiate_services!(:level => priority)

      # We can only really run ones that were succesfully queued          
      services_to_run = services.find_all { |s|
        queued_service_ids.include?(s.service_id)  
      }
      excluded_services = services.find_all {|s| 
        ! queued_service_ids.include?(s.service_id)  
      }

      logger.debug("Skipping services already queued for priority #{priority}: #{excluded_services.collect {|s|s.service_id}.inspect}") unless excluded_services.blank?
        
      next if services_to_run.empty?
      
      bundle = ServiceBundle.new(services_to_run , priority)
      bundle.handle(@user_request, request.session_options[:id])            
    end
    

    # Now we run background services. 
    # Now we do some crazy magic, start a Thread to run our background
    # services. We are NOT going to wait for this thread to join,
    # we're going to let it keep doing it's thing in the background after
    # we return a response to the browser
    backgroundThread = Thread.new(@collection, @user_request) do | t_collection,  t_request|
      # Tell our AR extension not to allow implicit checkouts
      ActiveRecord::Base.forbid_implicit_checkout_for_thread! if ActiveRecord::Base.respond_to?("forbid_implicit_checkout_for_thread!")
      
      # got to reserve an AR connection for our main 'background traffic director'
      # thread, so it has a connection to use to mark services as failed, at least. 
      ActiveRecord::Base.connection_pool.with_connection do
        begin
          # Deal with ruby's brain dead thread scheduling by setting
          # bg threads to a lower priority so they don't interfere with fg
          # threads.
          Thread.current.priority = -1
          
        
          ('a'..'z').each do | priority |
            # Only run the services that are runnable, that have their ids listed
            services = t_collection.instantiate_services!(:level => priority)
            services_to_run = services.find_all { |s|
              queued_service_ids.include?(s.service_id)  
            }
            excluded_services = services.find_all {|s| 
              ! queued_service_ids.include?(s.service_id)  
            }
  
            
            logger.debug("Skipping services already queued for priority #{priority}: #{excluded_services.collect {|s|s.service_id}.inspect}") unless excluded_services.blank?
            
              
            next if services_to_run.empty?
        
            bundle = ServiceBundle.new(services_to_run , priority)
            bundle.handle(t_request, request.session_options[:id])
          end        
       rescue Exception => e
         #debugger
          # We are divorced from any request at this point, not much
          # we can do except log it. Actually, we'll also store it in the
          # db, and clean up after any dispatched services that need cleaning up.
          # If we're catching an exception here, service processing was
          # probably interrupted, which is bad. You should not intentionally
          # raise exceptions to be caught here.
          Thread.current[:exception] = e
          logger.error("Background Service execution exception1: #{e}\n\n   " + clean_backtrace(e).join("\n"))                
       end
     end
    end
  end


  
end

