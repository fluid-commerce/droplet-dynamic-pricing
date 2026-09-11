# frozen_string_literal: true

require "faraday"
require "faraday/net_http_persistent"

module Connections
  class Fluid
    TIMEOUT = ENV.fetch("FLUID_API_TIMEOUT", 30).to_i
    OPEN_TIMEOUT = ENV.fetch("FLUID_API_OPEN_TIMEOUT", 10).to_i

    # The deadline Fluid actually enforces on a synchronous callback.
    #
    # It comes from the callback DEFINITION, not from the registration:
    # Callback::Client#make_requests reads
    # definition.maximum_timeout_in_milliseconds (falling back to 20_000) and
    # hands it straight to Typhoeus, which is what sets response.timed_out?.
    # A registration's timeout_in_seconds is never read by any Fluid code — it
    # survives only in that app's client.md — so writing a bigger number there
    # buys this droplet nothing.
    #
    # The three definitions this droplet is alerted on declare 5000ms:
    #   cart_item_added.yml, cart_subscription_added.yml,
    #   cart_subscription_removed.yml
    # Others (cart_email_on_create, cart_customer_logged_in,
    # cart_country_changed) omit the field and get 20s. 5 is the tightest, so it
    # is the one the ladder below has to fit.
    #
    # Mirrored here because this droplet cannot read Fluid's definition files.
    # If Fluid retunes those YAMLs, this constant is what has to follow.
    CALLBACK_BUDGET = 5

    # One attempt, sized against CALLBACK_BUDGET rather than against nothing.
    #
    # This was 5s — the WHOLE budget — so a single hung Fluid call spent the
    # entire deadline by itself, and the retry after it could not arrive in time
    # by construction. The values above (30s) are unreachable on this path for
    # the same reason: a call allowed 30s can only ever time out long after
    # Fluid has given up and served the cart. That is the shape behind both the
    # 19.84s CURRENT-3248 traces and the TM3 timeouts: ~1.4% of dispatches, all
    # in the tail, on callbacks whose median is ~1s.
    #
    # 2s is still ~2.5x the 0.70-0.79s that PATCH update_cart_items_prices
    # measures in production, so a legitimately slow call is not cut off, and it
    # keeps the full ladder (2 attempts + backoff = 4.25s) inside the budget.
    # Tunable without a code change; the tests fail if a tuning puts the ladder
    # back outside the budget.
    CALLBACK_TIMEOUT = ENV.fetch("FLUID_CALLBACK_API_TIMEOUT", 2).to_i
    CALLBACK_OPEN_TIMEOUT = ENV.fetch("FLUID_CALLBACK_API_OPEN_TIMEOUT", 2).to_i

    # The callback profile keeps a retry, bounded so the ladder cannot outlive the
    # budget: 2 attempts at 2s plus 0.25s between them is 4.25s, inside the 5s
    # CALLBACK_BUDGET.
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
