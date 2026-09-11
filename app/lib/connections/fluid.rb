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

    # The callback profile keeps a retry, bounded so the ladder cannot outlive the
    # budget: 2 attempts at 5s plus 0.25s between them is ~10.25s, inside 20s.
    #
    # It has to keep one. faraday-retry only retries IDEMPOTENT_METHODS
    # (delete/get/head/options/put), and every cart write here is a PATCH, so the
    # ladder has only ever applied to the READS — and the reads are exactly where
    # giving up early is dangerous. variant_country_rows rescues a failed variant
    # GET to nil, and country_safe_price then forwards the payload price
    # unchecked and lets Fluid lock it: the STU2-3108 cross-country echo, where a
    # PH cart was charged the CAD figure. Dropping the retry outright would turn
    # that fail-open from a rare blip into a routine outcome under load, which is
    # a wrong charge rather than a missing discount.
    CALLBACK_RETRIES = ENV.fetch("FLUID_CALLBACK_API_RETRIES", 1).to_i
    CALLBACK_RETRY_INTERVAL = ENV.fetch("FLUID_CALLBACK_API_RETRY_INTERVAL", "0.25").to_f

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
    # What changes on the callback profile is the SIZE of the ladder, not its
    # existence: 4 attempts at 30s (~123s worst case, six times a budget of 20s)
    # becomes 2 at 5s. See CALLBACK_RETRIES for why removing it entirely would
    # trade a slow callback for a wrong price.
    def self.create_connection(profile: :job)
      callback = profile == :callback

      Faraday.new(url: Setting.fluid_api.base_url) do |conn|
        conn.request :retry,
                     max: callback ? CALLBACK_RETRIES : 3,
                     interval: callback ? CALLBACK_RETRY_INTERVAL : 0.5,
                     backoff_factor: 2,
                     interval_randomness: 0.2,
                     exceptions: [ Faraday::TimeoutError ]
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
