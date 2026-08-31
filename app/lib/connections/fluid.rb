# frozen_string_literal: true

require "faraday"
require "faraday/net_http_persistent"

module Connections
  class Fluid
    TIMEOUT = ENV.fetch("FLUID_API_TIMEOUT", 30).to_i
    OPEN_TIMEOUT = ENV.fetch("FLUID_API_OPEN_TIMEOUT", 10).to_i

    # Fluid abandons a synchronous callback at the registration's
    # timeout_in_seconds, which Callback validates at <= 20s and registers at 20s
    # by default. The values above are therefore unreachable on that path: a call
    # allowed 30s can only ever time out AFTER Fluid has given up and served the
    # cart. That is the shape behind the 19.84s callback timeout in the
    # CURRENT-3248 traces.
    #
    # 5s is ~6x the 0.70-0.79s that PATCH update_cart_items_prices measures in
    # production, and leaves room for the several calls a callback makes in
    # sequence. Tunable without a code change if that proves tight.
    CALLBACK_TIMEOUT = ENV.fetch("FLUID_CALLBACK_API_TIMEOUT", 5).to_i
    CALLBACK_OPEN_TIMEOUT = ENV.fetch("FLUID_CALLBACK_API_OPEN_TIMEOUT", 2).to_i

    # Shared, cached connection
    # Uses persistent connections with idle timeout for optimal performance.
    # - Connections are reused when jobs run frequently (no TLS handshakes, lower latency)
    # - Idle connections are closed after 5 seconds, avoiding stale connection errors
    # - Retry middleware handles transient timeout failures
    def self.connection
      @connection ||= create_connection
    end

    # `profile: :callback` for anything answering one of Fluid's synchronous
    # callbacks, where the shopper's request is blocked on the response; :job
    # (the default) for background work, where nobody is waiting.
    #
    # Retries are dropped on the callback profile. The only retried exception is
    # Faraday::TimeoutError — precisely the case where the callback budget is
    # already spent — so the ladder cannot help there. It only holds a Puma
    # thread for up to ~2 minutes (4 attempts at 30s plus backoff) while
    # re-issuing writes against a cart Fluid has already served. Those late
    # writes still land, which is one way a cart price appears to change on its
    # own.
    def self.create_connection(profile: :job)
      callback = profile == :callback

      Faraday.new(url: Setting.fluid_api.base_url) do |conn|
        unless callback
          conn.request :retry,
                       max: 3,
                       interval: 0.5,
                       backoff_factor: 2,
                       interval_randomness: 0.2,
                       exceptions: [ Faraday::TimeoutError ]
        end
        conn.request :json
        conn.response :json, content_type: /\bjson$/
        conn.adapter :net_http_persistent, pool_size: 5 do |http|
          http.idle_timeout = 5
        end
        conn.options.timeout = callback ? CALLBACK_TIMEOUT : TIMEOUT
        conn.options.open_timeout = callback ? CALLBACK_OPEN_TIMEOUT : OPEN_TIMEOUT
        conn.headers["Content-Type"] = "application/json"
        conn.headers["x-fluid-client"] = "fluid-middleware"
      end
    end
  end
end
