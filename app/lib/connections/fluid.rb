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

    # Held back from every call's timeout for the work that is NOT an outbound
    # call: deserialising the payload, the pricing decision itself, rendering
    # the response, and the trip back to Fluid. A call handed the whole budget
    # would finish exactly as Fluid stops listening.
    CALLBACK_MARGIN = ENV.fetch("FLUID_CALLBACK_API_MARGIN", "0.25").to_f

    # The CEILING for one call, not a slice of the budget.
    #
    # A flat slice was the wrong shape: any value tight enough to survive a hung
    # call also kills a legitimately slow one. DeadlineTimeout narrows each call
    # to what CallbackBudget says is actually left, so this is only the most a
    # call may ever be given — which is the budget minus the margin, because a
    # call handed the whole budget would answer exactly as Fluid stops
    # listening.
    CALLBACK_TIMEOUT = ENV.fetch("FLUID_CALLBACK_API_TIMEOUT", CALLBACK_BUDGET - CALLBACK_MARGIN).to_f

    CALLBACK_OPEN_TIMEOUT = ENV.fetch("FLUID_CALLBACK_API_OPEN_TIMEOUT", 2).to_i

    # The callback profile does NOT retry, and the retry it used to have was
    # never doing what it claimed.
    #
    # It was justified as protecting the reads: a failed variant GET made
    # country_safe_price forward the payload price unchecked (STU2-3108). But
    # with a per-call timeout equal to the budget, the first attempt only raised
    # AT the deadline — so the retry started after Fluid had served the cart. It
    # rescued nothing and spent 5s more answering nobody.
    #
    # Under a deadline that holds by construction: a timeout means the budget is
    # spent, so there is nothing left to retry into. And the STU2-3108 exposure
    # is closed at its source now — country_safe_price refuses an item whose
    # lookup failed rather than forwarding a price it could not check.
    #
    # Background work keeps its own retries; nobody is waiting on those.
    CALLBACK_RETRIES = ENV.fetch("FLUID_CALLBACK_API_RETRIES", 0).to_i
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
    # Internal: Narrow each callback call to what is left of the deadline.
    #
    # A connection-level timeout is one number for the whole request; the
    # budget it has to fit in is spent progressively, by every call before this
    # one. Reading CallbackBudget per request is what lets an early call take
    # seconds while a late one fails fast — and outside a callback request there
    # is no budget, so the connection's own timeout stands.
    class DeadlineTimeout < Faraday::Middleware
      def call(env)
        remaining = CallbackBudget.remaining
        env.request.timeout = remaining if remaining

        @app.call(env)
      end
    end

    def self.create_connection(profile: :job)
      callback = profile == :callback

      Faraday.new(url: Setting.fluid_api.base_url) do |conn|
        if callback
          conn.use DeadlineTimeout
        else
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
