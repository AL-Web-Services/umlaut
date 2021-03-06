# We proxy cover images from foreign sources through Umlaut sometimes, in order
# to switch their access from http to https to avoid browser warnings on an
# https page.  This controller does that.
#
# It does NOT take URL in request parameters, but instead takes a response ID.
# it will only proxy urls already stored in umlaut responses, so this is not
# an open proxy with the security problems that would cause.
class ResourceController < UmlautController
  require 'open-uri'
  require 'timeout'

  # seconds to wait for thing were proxying. Yeah, fairly big num seems neccesary
  # for Amazon at least.
  HttpTimeout = 4

  # We really ought to _stream_ the remote response to our client, but I
  # couldn't get that to work how I wanted in Rails2. Even using
  # render :text=>proc, problem is we needed to know the content-type before
  # we read any of the response, which we didn't. This implementation holds
  # the whole image in memory for a second while it delivers it, oh well.
  # doesn't seem to effect speed much, even though it's not optimal.
  def proxy
    svc_resp = ServiceResponse.find(params[:id])
    url_str =  svc_resp.view_data[:url]
    uri = nil
    begin
      uri = URI(url_str)
    rescue
      raise Exception.new("resource#proxy can only handle String urls, not '#{url.inspect}'")
    end

    proxied_headers = proxy_headers( request, uri.host )

    # open-uri :read_timeout is not behaving reliably, resort to Timeout.timeout
    # should we just be using raw Net::Http and give up on open-uri? remember
    # to update timeout exceptions in rescue below if you change.
    remote_response = Timeout.timeout(HttpTimeout) {  open(uri, 'rb', proxied_headers) }

    # copy certain headers to our proxied response
    ["Content-Type", "Cache-Control", "Expires", "Content-Length", "Last-Modified", "Etag", "Date"].each do |key|
      value = remote_response.meta[key.downcase] # for some reason open-uri lowercases em
      # rack doens't like it if we set a nil value here.
      response.headers[key] = value unless value.blank?
    end

    response.headers["X-Original-Url"] = url_str

    # And send the actual result out
    render(:text => remote_response.read)
  rescue Timeout::Error, Errno::ECONNREFUSED, Errno::ETIMEDOUT => e
    msg                = "#{e.inspect}: waiting for image proxy from `#{url_str}`; timeout is currently set to #{HttpTimeout}s; returning broken image"
    backtrace          = Umlaut::Util.clean_backtrace(e)

    logger.warn("#{msg}\n  #{backtrace.join("\n  ")}")

    response.headers['X-Original-Url'] = url_str
    render :text => msg, :status => 504
  end

  protected

  # Generate headers as if we are a proxy server, to be more or less honest
  # and to maybe keep Google et al from rate throttling us.
  # This is kind of copy and paste of UmlautHttp#proxy_like_headers, but that
  # method was written to require an UmlautRequest, which we don't have here.
  # TODO should refactor to DRY.
  # Argument here is a Rails Request
  def proxy_headers( request, host  )
    orig_env = request.headers
    header = {}
    header["User-Agent"] = orig_env['HTTP_USER_AGENT'] || 'Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.9) Gecko/2008061015 Firefox/3.0'
    header['Accept'] = orig_env['HTTP_ACCEPT'] || 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'
    header['Accept-Language'] = orig_env['HTTP_ACCEPT_LANGUAGE'] || 'en-us,en;q=0.5'
    header['Accept-Encoding'] = orig_env['HTTP_ACCEPT_ENCODING'] || ''
    header["Accept-Charset"] = orig_env['HTTP_ACCEPT_CHARSET'] || 'UTF-8,*'

    # Set referrer to be, well, an Umlaut page, like the one we are
    # currently generating would be best. That is, the resolve link.
    header["Referer"] = "http://#{orig_env['HTTP_HOST']}#{orig_env['REQUEST_URI']}"

    # Proxy X-Forwarded headers.

    # The original Client's ip, most important and honest. Look for
    # and add on to any existing x-forwarded-for, if neccesary, as per
    # x-forwarded-for convention.
    header['X-Forwarded-For'] =  (orig_env['HTTP_X_FORWARDED_FOR']) ?
       (orig_env['HTTP_X_FORWARDED_FOR'].to_s + ', ' + request.remote_ip.to_s) :
       request.remote_ip.to_s

    #Theoretically the original host requested by the client in the Host HTTP request header. We're disembling a bit.
    header['X-Forwarded-Host'] = host if host
    # The proxy server: That is, Umlaut, us.
    header['X-Forwarded-Server'] = orig_env['SERVER_NAME'] || ''

    return header
  end
end