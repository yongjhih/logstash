# encoding: utf-8
require "logstash/outputs/base"
require "logstash/namespace"

class LogStash::Outputs::Http < LogStash::Outputs::Base
  # This output lets you `PUT` or `POST` events to a
  # generic HTTP(S) endpoint
  #
  # Additionally, you are given the option to customize
  # the headers sent as well as basic customization of the
  # event json itself.

  config_name "http"
  milestone 1

  # URL to use
  config :url, :validate => :string, :required => :true

  # validate SSL?
  config :verify_ssl, :validate => :boolean, :default => true

  # What verb to use
  # only put and post are supported for now
  config :http_method, :validate => ["put", "post"], :required => :true

  # Custom headers to use
  # format is `headers => ["X-My-Header", "%{host}"]
  config :headers, :validate => :hash

  # Content type
  #
  # If not specified, this defaults to the following:
  #
  # * if format is "json", "application/json"
  # * if format is "form", "application/x-www-form-urlencoded"
  config :content_type, :validate => :string

  # This lets you choose the structure and parts of the event that are sent.
  #
  #
  # For example:
  #
  #    mapping => ["foo", "%{host}", "bar", "%{type}"]
  config :mapping, :validate => :hash

  # Set the format of the http body.
  #
  # If form, then the body will be the mapping (or whole event) converted
  # into a query parameter string (foo=bar&baz=fizz...)
  #
  # If message, then the body will be the result of formatting the event according to message
  #
  # Otherwise, the event is sent as json.
  config :format, :validate => ["json", "form", "message"], :default => "json"

  config :message, :validate => :string

  public
  def register
    require "ftw"
    require "uri"
    @agent = FTW::Agent.new
    # TODO(sissel): SSL verify mode?

    if @content_type.nil?
      case @format
        when "form" ; @content_type = "application/x-www-form-urlencoded"
        when "json" ; @content_type = "application/json"
      end
    end
    if @format == "message"
      if @message.nil?
        raise "message must be set if message format is used"
      end
      if @content_type.nil?
        raise "content_type must be set if message format is used"
      end
      unless @mapping.nil?
        @logger.warn "mapping is not supported and will be ignored if message format is used"
      end
    end
  end # def register

  public
  def receive(event)
    return unless output?(event)

    if @mapping
      evt = Hash.new
      @mapping.each do |k,v|
        evt[k] = event.sprintf(v)
      end
    else
      evt = event.to_hash
    end

    case @http_method
    when "put"
      request = @agent.put(event.sprintf(@url))
    when "post"
      request = @agent.post(event.sprintf(@url))
    else
      @logger.error("Unknown verb:", :verb => @http_method)
    end

    #request["User-Agent"] = "Mozilla/5.0 (Linux; Android 4.3) AppleWebkit/534.30 (KHTML, like Gecko) Version/4.0 Mobile Safari/534.30"
    request["User-Agent"] = "Android"
    request["Accept"] = "text/html,application/xml,application/json,application/xhtml+xml,text/html;q=0.9,text/plain;q=0.8,image/png,*/*;q=0.5"
    
    if @headers
      @headers.each do |k,v|
        request.headers[k] = event.sprintf(v)
      end
    end

    request["Content-Type"] = @content_type

    begin
      if @format == "json"
        request.body = evt.to_json
      elsif @format == "message"
        request.body = event.sprintf(@message)
      else
        request.body = encode(evt)
      end
      #puts "#{request.port} / #{request.protocol}"
      #puts request
      #puts 
      #puts request.body
      response = @agent.execute(request)

      # Consume body to let this connection be reused
      rbody = ""
      response.read_body { |c| rbody << c }
      #puts rbody
    rescue Exception => e
      @logger.warn("Unhandled exception", :request => request, :response => response, :exception => e, :stacktrace => e.backtrace)
    end
  end # def receive

  def encode(hash)
    return hash.map do |key, value|
      if key.nil? or key.empty?
      elsif key =~ /^@/
      elsif key == "type"
      elsif !value.nil? and value.is_a?(Hash)
        if key =~ /DEVICE_FEATURES/
          escaped_value = CGI.escape(flatten_without_boolean_value(value).to_s)
          "\n" + CGI.escape(key) + "=" + escaped_value + "\n"
        else
          escaped_value = CGI.escape(flatten(value).to_s)
          "\n" + CGI.escape(key) + "=" + escaped_value + "\n"
        end
      else
        escaped_value = CGI.escape(value.to_s)
        CGI.escape(key) + "=" + escaped_value
      end

    end.join("&")
  end # def encode

  def flatten_without_boolean_value(parent=nil, hash)
    return hash.map {|k, v|
      if k.nil? or k.empty?
      else
        v.is_a?(Hash) ?
          parent.nil? ? flatten_without_boolean_value(k, v) : flatten_without_boolean_value("#{parent}.#{k}", v) :
          if (v == true)
            parent.nil? ? "#{k}" : "#{parent}.#{k}"
          else
            if k == "glEsVersion"
              parent.nil? ? "#{k} = #{v}" : "#{parent}.#{k} = #{v}"
            else
              parent.nil? ? "#{k}=#{v}" : "#{parent}.#{k}=#{v}"
            end
          end
      end
    }.reject(&:nil?).join("\n")
  end

  def flatten(parent=nil, hash)
    return hash.map {|k, v|
      if k.nil? or k.empty?
      else
        v.is_a?(Hash) ?
          parent.nil? ? flatten(k, v) : flatten("#{parent}.#{k}", v) :
          parent.nil? ? "#{k}=#{v}" : "#{parent}.#{k}=#{v}"
      end
    }.reject(&:nil?).join("\n")
  end
end
