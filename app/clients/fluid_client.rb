class FluidClient
  include HTTParty
  include Fluid::Droplets
  include Fluid::Webhooks
  include Fluid::CallbackDefinitions
  include Fluid::CallbackRegistrations
  include Fluid::Customers
  include Fluid::Carts
  include Fluid::Metafields
  include Fluid::Subscriptions

  base_uri Setting.fluid_api.base_url
  format :json

  Error                 = Class.new(StandardError)
  AuthenticationError   = Class.new(Error)
  ResourceNotFoundError = Class.new(Error)
  APIError              = Class.new(Error)

  def initialize(auth_token = nil)
    @http = self.class
    @auth_token = auth_token
    update_headers
  end

  def get(path, options = {})
    handle_response(@http.get(path, format_options(options)))
  end

  def post(path, options = {})
    handle_response(@http.post(path, format_options(options)))
  end

  def put(path, options = {})
    handle_response(@http.put(path, format_options(options)))
  end

  def patch(path, options = {})
    handle_response(@http.patch(path, format_options(options)))
  end

  def delete(path, options = {})
    handle_response(@http.delete(path, format_options(options)))
  end

private

  def update_headers
    self.class.headers "Authorization" => "Bearer #{@auth_token}", "Content-Type" => "application/json"
  end

  def format_options(options)
    options[:body] = options[:body].to_json if options[:body].is_a?(Hash)

    options
  end

  def handle_response(response)
    case response.code
    when 200..299
      response.parsed_response
    when 401
      raise AuthenticationError, response
    when 404
      raise ResourceNotFoundError, response
    else
      raise APIError, response
    end
  end
end
