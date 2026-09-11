# frozen_string_literal: true

class FluidClient
  include Fluid::Droplets
  include Fluid::Webhooks
  include Fluid::CallbackDefinitions
  include Fluid::CallbackRegistrations
  include Fluid::Customers
  include Fluid::Members
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
    handle_response(timed { connection.get(path, options[:query], auth_headers) })
  end

  def post(path, options = {})
    handle_response(timed { connection.post(path, options[:body], auth_headers) })
  end

  def put(path, options = {})
    handle_response(timed { connection.put(path, options[:body], auth_headers) })
  end

  def patch(path, options = {})
    handle_response(timed { connection.patch(path, options[:body], auth_headers) })
  end

  def delete(path, options = {})
    handle_response(timed { connection.delete(path, options[:query], auth_headers) })
  end

private

  # Internal: Measure a call when the shopper is blocked on it.
  #
  # Only the :callback profile is tallied — see CallbackHttpTally. The timing is
  # in an ensure so a call that raises (a timeout above all) still reports the
  # time it burned, which is the case the measurement exists for.
  def timed
    return yield unless @profile == :callback

    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    begin
      yield
    ensure
      CallbackHttpTally.record(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at)
    end
  end

  # Shared per thread, so the TLS handshake is paid once rather than once per
  # callback. See Connections::Fluid.connection.
  def connection
    Connections::Fluid.connection(profile: @profile)
  end

  # Per REQUEST, not on the connection: the token is per company and the
  # connection is shared, so stamping it on the connection would hand one
  # company's request another company's credentials.
  def auth_headers
    return {} if @auth_token.blank?

    { "Authorization" => "Bearer #{@auth_token}" }
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
