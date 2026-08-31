# frozen_string_literal: true

class FluidClient
  include Fluid::Droplets
  include Fluid::Webhooks
  include Fluid::CallbackDefinitions
  include Fluid::CallbackRegistrations
  include Fluid::Customers
  include Fluid::Carts
  include Fluid::Subscriptions
  include Fluid::Metafields
  include Fluid::Variants

  Error                 = Class.new(StandardError)
  AuthenticationError   = Class.new(Error)
  ResourceNotFoundError = Class.new(Error)
  APIError              = Class.new(Error)
  TimeoutError          = Class.new(Error)

  # `profile` picks the HTTP budget, not the endpoint — see Connections::Fluid.
  # Anything answering one of Fluid's synchronous callbacks must pass :callback
  # so a slow Fluid call fails inside the callback's budget instead of outliving
  # it. Everything else (jobs, webhooks, admin UI) wants the default.
  def initialize(auth_token = nil, profile: :job)
    @auth_token = auth_token
    @profile = profile
  end

  def get(path, options = {})
    handle_response(connection.get(path, options[:query]))
  end

  def post(path, options = {})
    handle_response(connection.post(path, options[:body]))
  end

  def put(path, options = {})
    handle_response(connection.put(path, options[:body]))
  end

  def patch(path, options = {})
    handle_response(connection.patch(path, options[:body]))
  end

  def delete(path, options = {})
    handle_response(connection.delete(path, options[:query]))
  end

private

  def connection
    @connection ||= Connections::Fluid.create_connection(profile: @profile).tap do |conn|
      conn.headers["Authorization"] = "Bearer #{@auth_token}"
    end
  end

  def handle_response(response)
    case response.status
    when 200..299
      response.body
    when 401
      raise AuthenticationError, "Authentication failed: #{response.status}"
    when 404
      raise ResourceNotFoundError, "Resource not found: #{response.status}"
    else
      raise APIError, "API error: #{response.status} - #{response.body}"
    end
  rescue Faraday::TimeoutError => e
    raise TimeoutError, "Request timed out: #{e.message}"
  rescue Faraday::ConnectionFailed => e
    raise Error, "Connection failed: #{e.message}"
  end
end
