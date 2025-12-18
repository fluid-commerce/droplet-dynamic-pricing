# frozen_string_literal: true

require 'faraday'
require 'faraday/net_http_persistent'

module Connections
  class Fluid
    PUBLIC_BASE_URL = ENV.fetch('FLUID_API_BASE_URL', nil)
    TIMEOUT = ENV.fetch('FLUID_API_TIMEOUT', 30).to_i
    OPEN_TIMEOUT = ENV.fetch('FLUID_API_OPEN_TIMEOUT', 10).to_i

    # Shared, cached connection
    # Uses persistent connections with idle timeout for optimal performance.
    # - Connections are reused when jobs run frequently (no TLS handshakes, lower latency)
    # - Idle connections are closed after 5 seconds, avoiding stale connection errors
    # - Retry middleware handles transient timeout failures
    def self.connection
      @connection ||= create_connection
    end

    def self.create_connection
      Faraday.new(url: PUBLIC_BASE_URL) do |conn|
        conn.request :retry,
                     max: 3,
                     interval: 0.5,
                     backoff_factor: 2,
                     interval_randomness: 0.2,
                     exceptions: [Faraday::TimeoutError]
        conn.request :json
        conn.response :json, content_type: /\bjson$/
        conn.adapter :net_http_persistent, pool_size: 5 do |http|
          http.idle_timeout = 5
        end
        conn.options.timeout = TIMEOUT
        conn.options.open_timeout = OPEN_TIMEOUT
        conn.headers['Content-Type'] = 'application/json'
        conn.headers['x-fluid-client'] = 'fluid-middleware'
      end
    end
  end
end
