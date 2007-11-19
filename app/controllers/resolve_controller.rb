# Requests to the Resolve controller are OpenURLs.
# There is one exception: Instead of an OpenURL, you can include the
# parameter umlaut.request_id=[some id] to hook up to a pre-existing
# umlaut request (that presumably was an OpenURL). 

class ResolveController < ApplicationController
  before_filter :init_processing
  
  after_filter :save_request
  
  # Take layout from config, default to resolve_basic.rhtml layout. 
  layout AppConfig.param("resolve_layout", "resolve_basic"), 
         :except => [:banner_menu, :bannered_link_frameset, :partial_html_sections]
  require 'json/lexer'
  require 'json/objects'
  require 'oai'
  require 'open_url'
  require 'collection'

  # If a background service was started more than 30 seconds
  # ago and isn't finished, we assume it died.
  BACKGROUND_SERVICE_TIMEOUT = 30
  
  # set up names of partials for differnet blocks on index page
  @@partial_for_block = {}
  @@partial_for_block[:holding] = AppConfig.param("partial_for_holding", "holding")
  def self.partial_for_block ; @@partial_for_block ; end
  
  # Divs to be updated by the background updater. See background_update.rjs
  # Sorry that this is in a class variable for now, maybe we can come up
  # with a better way to encapsulate this info.
  @@background_updater = {:divs  => 
                         [{ :div_id => "fulltext_wrapper", 
                            :partial => "fulltext",
                            :service_type_values => ["fulltext"]
                          },
                          { :div_id => "holding", 
                            :partial => @@partial_for_block[:holding],
                            :service_type_values => ["holding","holding_search"]
                          },
                          {:div_id => "highlighted_links",
                           :partial => "highlighted_links_start",
                           :service_type_values => ["highlighted_link"]},
                           
                           ],
                          :error_div =>
                          { :div_id => 'service_errors',
                            :partial => 'service_errors'}
                        }
   #re-use some of that for partial html sections too.
   # see partial_html_sections action. 
   @@partial_html_sections = @@background_updater[:divs]


  # Retrives or sets up the relevant Umlaut Request, and returns it. 
  def init_processing

    
    @user_request ||= Request.new_request(params, session, request )

    
    # Ip may be simulated with req.ip in context object, or may be
    # actual, request figured it out for us. 
    @collection = Collection.new(@user_request.client_ip_addr, session)      
    @user_request.save!

    # Set 'timed out' background services to dead if neccesary. 
    @user_request.dispatched_services.each do | ds |
        if ( (ds.status == DispatchedService::InProgress ||
              ds.status == DispatchedService::Queued ) &&
              (Time.now - ds.updated_at) > BACKGROUND_SERVICE_TIMEOUT)

              ds.store_exception( Exception.new("background service timed out; thread assumed dead.")) unless ds.exception_info
              # Fail it temporary, it'll be run again. 
              ds.status = DispatchedService::FailedTemporary
              ds.save!
        end
    end
    
    return @user_request
  end

  # Expire expired service_responses if neccesary.
  # See app config params 'response_expire_interval' and
  # 'response_expire_crontab_format'. 
    
  def expire_old_responses
    require 'CronTab'
    
    expire_interval = AppConfig.param('response_expire_interval')
    crontab_format = AppConfig.param('response_expire_crontab_format')

    unless (expire_interval || crontab_format)      
      # Not needed, nothing to expire
      return nil
    end
    
    responses_expired = 0
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
          
          serv_id = ds.service.id
          expired_responses = @user_request.service_types.each do |st|
            
            if st.service_response.service.id == serv_id
              @user_request.service_types.delete(st)
              responses_expired += 1
              st.service_response.destroy
              st.destroy
            end
          end
          @user_request.dispatched_services.delete(ds)
          ds.destroy
      end
    end
  end

  def setup_banner_link
    # We keep the id of the ServiceType join object in param 'umlaut.id' for
    # banner frameset link type actions. Take it out and stick the object
    # in a var if available.    
    joinID = params[:'umlaut.id']
    
    @service_type_join = @user_request.service_types.find_all_by_id(joinID).first if joinID
    
    # default?    
    unless ( @service_type_join )
       
      @service_type_join = 
        @user_request.service_types.find_by_service_type_value_id(
      ServiceTypeValue[:fulltext].id )
    end

    

    unless @service_type_join 
       raise "No service_type_join found!"
    end
    
  end

  def save_request
    @user_request.save!
  end
 		
  def index
    #self.init_processing # handled by before_filter 
    self.service_dispatch()
    @user_request.save! 


    # link is a ServiceType object
    link = should_skip_menu
    if (! link.nil? )
      hash = LinkRouterController::frameset_action_params( link ).merge('umlaut.skipped_menu' => 'true')
      redirect_to hash
    else
      # Render configed view, if configed, or "index" view if not. 
      view = AppConfig.param("resolve_view", "resolve/index")
      render :template => view
    end
  end


  
  # Show a link to something in a frameset with a mini menu in a banner. 
  def bannered_link_frameset
  
      # Normally we should already have loaded the request in the index method,
      # and our before filter should have found the already loaded request
      # for us. But just in case, we can load it here too if there was a
      # real open url. This might happen on re-loads (after a long time or
      # cookie expire!) or in other weird cases.
      # If it's not neccesary, no services will be dispatched,
      # service_dispatch catches that. 
      self.service_dispatch()
      @user_request.save!
      
      self.setup_banner_link()
  end

  # The mini-menu itself. 
  def banner_menu
     self.setup_banner_link()
  end

  
  def json
  	self.index
  	@dispatch_hash = {:umlaut_response=>{:id => @requested_context_object.id}}
  	@dispatch_response.instance_variables.each { |ir |
  		@dispatch_hash[:umlaut_response][ir.to_s.gsub(/^@/, '')] = @dispatch_response.instance_variable_get(ir)
  	}
  	@headers["Content-Type"] = "text/javascript; charset=utf-8"
  	render_text @dispatch_hash.to_json 
		@context_object_handler.store(@dispatch_response)  	
  end

  # Action called by AJAXy thing to update resolve menu with
  # new stuff that got done in the background. 
  def background_update
    # Might be a better way to store/pass this info.
    # Divs that may possibly have new content. 
    divs = @@background_updater[:divs] || []
    error_div = @@background_updater[:error_div]

    # This method call render for us
    self.background_update_js(divs, error_div)     
  end

  # Display a non-javascript background service status page--or
  # redirect back to index if we're done.
  def background_status

    unless ( @user_request.any_services_in_progress? )
      # Just redirect to ordinary index, no need to show progress status. 
      # Re-construct the original request url
      params_hash = @user_request.original_co_params(:add_request_id => true)
            
      redirect_to(params_hash.merge({:controller=>"resolve", :action=>'index', :'umlaut.skip_resolve_menu' => params['umlaut.skip_resolve_menu']}))
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

    
    @partial_html_sections = @@partial_html_sections
    # calculate in progress for each section
    @partial_html_sections.each do |section|
         type_names = []
         type_names << section[:service_type_value] if section[:service_type_value]
         type_names.concat( section[:service_type_values] ) if section[:service_type_values]
       
         complete =  type_names.find { |n| @user_request.service_type_in_progress?(n) }.nil?

         section[:complete?] = complete
     end

    # Run the request if neccesary. 
    self.service_dispatch()
    @user_request.save!
    
    # Format?
    format = (params["umlaut.response_format"]) || "xml"
    
   if ( format == "xml" )      
      # The partial_html_sections.rhtml returns xml
      render(:content_type => "application/xml", :layout => false)
   elsif ( format == 'json' || format == "jsonp")
      
      # get the xml in a string
      xml_str = render_to_string(:layout=>false)
      # convert to hash
      data_as_hash = Hash.from_xml( xml_str )
      # And conver to json. Ta-da!
      json_str = data_as_hash.to_json

      # Handle jsonp.
      if ( format == "jsonp")
        procname = params["umlaut.jsonp"] || "onPartialHtmlSectionsLoaded"
        
        json_str = procname + "( " + json_str + " );"
      end

      render(:text => json_str, :content_type=> "text/x-json",:layout=>false )
    else
      raise ArgumentError.new("format requested (#{format}) not understood by action")
    end
  end
  
  def xml
		self.index
		umlaut_doc = REXML::Document.new
		root = umlaut_doc.add_element 'umlaut', 'id'=>@context_object_handler.id
		co_doc = REXML::Document.new @context_object.xml
		root.add co_doc.root
		umlaut_doc = @dispatch_response.to_xml(umlaut_doc)
  	@headers["Content-Type"] = "text/xml; charset=utf-8"
  	render_text umlaut_doc.write
		@context_object_handler.store(@dispatch_response)  	
  end  
  
  def description
  	service_dispatcher = self.init_processing 
    service_dispatcher.add_identifier_lookups(@context_object)
    service_dispatcher.add_identifier_lookups(@context_object)    
    service_dispatcher << AmazonService.new
    service_dispatcher << ServiceBundle.new(service_dispatcher.get_opacs(@collection))  	
    service_dispatcher.add_social_bookmarkers  	    
  	self.do_processing(service_dispatcher)  	 	
  end

  # Obsolete, we don't do this like this anymore. 
  #def web_search
  #	service_dispatcher = self.init_processing
  #  service_dispatcher.add_identifier_lookups(@context_object)
  #  service_dispatcher << ServiceBundle.new(service_dispatcher.get_link_resolvers(@collection) + service_dispatcher.get_opacs(@collection))  	
  #  service_dispatcher.add_search_engines    
  #	self.do_processing(service_dispatcher)  	     
  #end

  # Obsolete, more_like_this not currently happening. 
  #def more_like_this
  #	service_dispatcher = self.init_processing
  #  service_dispatcher.add_identifier_lookups(@context_object)
  #  service_dispatcher << ServiceBundle.new(service_dispatcher.get_link_resolvers(@collection) + service_dispatcher.get_opacs(@collection))
  #  service_dispatcher.add_search_engines
  #  service_dispatcher.add_social_bookmarkers  	
  #	self.do_processing(service_dispatcher)  	
  #	puts @dispatch_response.dispatched_services.inspect
  #  @dispatch_response.dispatched_services.each { | svc |
  #    if svc.respond_to?('get_similar_items') and !@dispatch_response.similar_items.keys.index(svc.identifier.to_sym)
  #      svc.get_similar_items(@dispatch_response)
  #    end
  #  }

  #	unless @params[:view]
  #	 @params[:view] = @dispatch_response.similar_items.keys.first.to_s
  	 
  #	end
  #	puts @dispatch_response.similar_items.keys.inspect
  #end

  # Obsolete, related titles functionality not currently happening. 
  #def related_titles
  #	service_dispatcher = self.init_processing
  #  service_dispatcher.add_identifier_lookups(@context_object)
  #  service_dispatcher << ServiceBundle.new(service_dispatcher.get_link_resolvers(@collection) + service_dispatcher.get_opacs(@collection))  	
  # 	self.do_processing(service_dispatcher)  	
  #end

  # table of contents pull-out page
  def toc

  end
    


  # Obsolete, I think. 
  #def help
  #	service_dispatcher = self.init_processing  
  #  service_dispatcher << ServiceBundle.new(service_dispatcher.get_link_resolvers(@collection))  	
  # 	self.do_processing(service_dispatcher)     
  #end

  def rescue_action_in_public(exception)
    render :template => "error/resolve_error"
  end  

  # Obsolete, I think. 
  def do_background_services
    if @params['background_id']
    	service_dispatcher = self.init_processing
    	background_service = BackgroundService.find_by_id(@params['background_id'])  
    	services = Marshal.load background_service.services
    	service_dispatcher << ServiceBundle.new(services)
    	self.do_processing(service_dispatcher)
 			@context_object_handler.store(@dispatch_response)			
 			background_service.destroy
      menu = []
      unless @dispatch_response.similar_items.empty?
        menu << 'umlaut-similar_items'
      end
      unless @dispatch_response.description.empty?
        menu << 'umlaut-description' 
      end
      unless @dispatch_response.table_of_contents.empty?
        menu << 'umlaut-table_of_contents'
      end
      unless @dispatch_response.external_links.empty?
        menu << 'umlaut-external_links'
      end    
      render :text=>menu.join(",") 	
  		history = History.find_or_create_by_session_id_and_request_id(session.session_id, @context_object_handler.id)
  		history.cached_response = Marshal.dump @dispatch_response
  
  		history.save      	
    else
      render :nothing => true    	
    end
  end
  
  protected

  # Based on app config and context, should we skip the resolve
  # menu and deliver a 'direct' link? Returns nil if menu
  # should be displayed, or the ServiceType join object
  # that should be directly linked to. 
  def should_skip_menu
    # For usabilty test, do NOT skip if coming from A-Z list/journal lookup.

    # First, is it over-ridden in url?
    if ( params['umlaut.skip_resolve_menu'] == 'false')
      return nil
    end
    # Otherwise, load from app config
    skip  = AppConfig.param('skip_resolve_menu', false) if skip.nil?

    if (skip.kind_of?( FalseClass ))
      # nope
      return nil
    end

    return_value = nil
    if (skip.kind_of?(Hash) )
      skip[:service_types].each do | service |
        service = ServiceTypeValue[service] unless service.kind_of?(ServiceTypeValue)  

        candidates = 
        @user_request.service_types.find(:all, 
          :conditions => ["service_type_value_id = ?", service.id])
        # Make sure we don't redirect to any known frame escapers!
        candidates.each do |st|
          
          unless known_frame_escaper?(st)
            return_value = st
            break;
          end
        end
        end
    elsif (skip.kind_of?(Proc ))
      return_value = skip.call( :request => @user_request )
    else
      logger.error( "Unexpected value in app config 'skip_resolve_menu'; assuming false." )
    end
    
    return return_value;    
  end

  # Param is a ServiceType join object. Tries to identify when it's a 
  # target which refuses to be put in a frameset, which we take into account
  # when trying to put it a frameset for our frame menu!
  # At the moment this is just hard-coded in for certain SFX targets only,
  # that is works for SFX targets only. We should make this configurable
  # with a lambda config.
  helper_method :'known_frame_escaper?'
  def known_frame_escaper?(service_type)

    # HIGHWIRE_PRESS_FREE is a collection of different hosts,
    # but MANY of them seem to be frame-escapers, so we black list them all!
    # Seems to be true of HIGHWIRE_PRESS stuff in general in fact, they're
    # all blacklisted. 
    bad_target_regexps = [/^WILSON\_/, 
        'SAGE_COMPLETE', /^HIGHWIRE_PRESS/,
        /^OXFORD_UNIVERSITY_PRESS/]
    # note that these will sometimes be proxied urls!
    # So we don't left-anchor the regexp. 
    bad_url_regexps = [/http\:\/\/www.bmj.com/,
                       /http\:\/\/bmj.bmjjournals.com/, 
                       /http\:\/\/www.sciencemag.org/,
                       /http\:\/\/([^.]+\.)\.ahajournals\.org/,
                       /http\:\/\/www\.circresaha\.org/,
                       /http\:\/\/www.businessweek\.com/,
                       /endocrinology-journals\.org/]
    
    response = service_type.service_response
    
    # We only work for SFX ones right now. 
    unless response.service.kind_of?(Sfx)      
      # Can't say it is, nope. 
      return false;
    end
    
    sfx_target_name = response.service_data[:sfx_target_name]
    url = response.url
    
    # Does our target name match any of our regexps?
    bad_target =  bad_target_regexps.find_all {|re| re === sfx_target_name  }.length > 0
    
    return bad_target if bad_target
    # Now check url if neccesary
    return bad_url_regexps.find_all {|re| re === url  }.length > 0    
  end
  
  # Helper method used here in controller for outputting js to
  # do the background service update. 
  def background_update_js(div_list, error_div_info=nil)
    render :update do |page|      
        # Calculate whether there are still outstanding responses _before_
        # we actually output them, to try and avoid race condition.
        # If no other services are running that might need to be
        # updated, stop the darn auto-checker! The author checker watches
        # a js boolean variable 'background_update_check'.
        svc_types =  ( div_list.collect { |d| d[:service_type_value] } ).compact
        # but also use the service_type_values plural key
        svc_types = svc_types.concat( div_list.collect{ |d| d[:service_type_values] } ).flatten.compact
        
        keep_updater_going = false
        svc_types.each do |type|
          keep_updater_going ||= @user_request.service_type_in_progress?(type)
          break if keep_updater_going # good enough, we need the updater to keep going
        end
    
        # Stop the Prototype PeriodicalExecuter object if neccesary. 
        if (! keep_updater_going )
          page << "umlaut_background_executer.stop();"
        end
          
        # Now update our content -- we don't try to figure out which divs have
        # new content, we just update them all. Too hard to figure it out. 
        div_list.each do |div|
          div_id = div[:div_id]
          next if div_id.nil?
          # default to partial with same name as div_id
          partial = div[:partial] || div_id 
            
          page.replace_html div_id, :partial => partial
        end

        # Now update the error section if neccesary
        if ( ! error_div_info.nil? &&
             @user_request.failed_service_dispatches.length > 0 )
             page.replace_html(error_div_info[:div_id],
                               :partial => error_div_info[:partial])             
        end
    end
  end

  def service_dispatch()
    
    expire_old_responses();
    
    # Foreground services
    (0..9).each do | priority |
      
      next if @collection.service_level(priority).empty?

      
      if AppConfig[:threaded_services]
        bundle = ServiceBundle.new(@collection.service_level(priority))
        bundle.handle(@user_request)            
      else
        @collection.service_level(priority).each do | svc |
          svc.handle(@user_request) unless @user_request.dispatched?(svc)
        end
      end        
    end

    # Background services. First register them all as queued, so status
    # checkers can see that.
    ('a'..'z').each do | priority |
      @collection.service_level(priority).each do | service |
        @user_request.dispatched_queued(service)
      end
    end
    # Now we do some crazy magic, start a Thread to run our background
    # services. We are NOT going to wait for this thread to join,
    # we're going to let it keep doing it's thing in the background after
    # we return a response to the browser
    messages = []
    backgroundThread = Thread.new(@collection, @user_request) do | t_collection,  t_request|
      begin
        messages << "Starting bg services at #{Time.now}"        
        logger.info("Starting background services in Thread #{Thread.current.object_id}")
        ('a'..'z').each do | priority |
           service_list = t_collection.service_level(priority)
           next if service_list.empty?
           logger.info("background: Making service bundle for #{priority}")
           bundle = ServiceBundle.new( service_list )
           bundle.debugging = true
           messages << "Starting bundle for priority #{priority} at #{Time.now}"
           bundle.handle( t_request )
           messages << "Done handling bundle for priority #{priority} at #{Time.now}"
           logger.info("background: Done handling for #{priority}")
        end
        messages << "All bg services complete at #{Time.now}"
        logger.info("Background services complete")
     rescue Exception => e
        # We are divorced from any request at this point, not much
        # we can do except log it. Actually, we'll also store it in the
        # db, and clean up after any dispatched services that need cleaning up.
        # If we're catching an exception here, service processing was
        # probably interrupted, which is bad. You should not intentionally
        # raise exceptions to be caught here. 
        Thread.current[:exception] = e
        logger.error("Background Service execution exception: #{e}")
        logger.error( e.backtrace.join("\n") )
     end
    end    
  end  
end

