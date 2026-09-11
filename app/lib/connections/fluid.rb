# frozen_string_literal: true

require "faraday"
require "faraday/net_http_persistent"

module Connections
  class Fluid
    TIMEOUT = ENV.fetch("FLUID_API_TIMEOUT", 30).to_i
    OPEN_TIMEOUT = ENV.fetch("FLUID_API_OPEN_TIMEOUT", 10).to_i

    # The deadline Fluid actually enforces on a synchronous callback, per
    # callback — and they are NOT all the same.
    #
    # It comes from the callback DEFINITION, not from the registration:
    # Callback::Client#make_requests reads
    # definition.maximum_timeout_in_milliseconds (falling back to 20_000) and
    # hands it straight to Typhoeus, which is what sets response.timed_out?.
    # A registration's timeout_in_seconds is never read by any Fluid code — it
    # survives only in that app's client.md — so writing a bigger number there
    # buys this droplet nothing.
    #
    # The first four declare maximum_timeout_in_milliseconds: 5000. The rest omit
    # the field and get Callback::Client::MAX_TIMEOUT_IN_MILLISECONDS, 20s.
    # Holding those to 5s would cut off the most call-heavy callbacks — the
    # login path alone makes 6-8 fixed calls plus 2 per item — while Fluid is
    # still listening for another fifteen seconds.
    #
    # Every callback in Callback::SERVED_PATHS is listed, so a name missing here
    # means Fluid grew a definition this droplet has not caught up with.
    #
    # Mirrored here because this droplet cannot read Fluid's definition files.
    # If Fluid retunes those YAMLs, this map is what has to follow.
    CALLBACK_BUDGETS = {
      "cart_item_added"           => 5,
      "cart_item_updated"         => 5,
      "cart_subscription_added"   => 5,
      "cart_subscription_removed" => 5,
      "cart_country_changed"      => 20,
      "cart_customer_attached"    => 20,
      "cart_customer_detached"    => 20,
      "cart_customer_logged_in"   => 20,
      "cart_email_on_create"      => 20,
    }.freeze

    # What an unrecognised callback is assumed to have. The tightest, so a
    # definition added in Fluid without a matching entry above is treated
    # conservatively rather than being handed a budget it may not have.
    CALLBACK_BUDGET = 5

    # Held back from every call's timeout for the work that is NOT an outbound
    # call: deserialising the payload, the pricing decision itself, rendering
    # the response, and the trip back to Fluid. A call handed the whole budget
    # would finish exactly as Fluid stops listening.
    CALLBACK_MARGIN = ENV.fetch("FLUID_CALLBACK_API_MARGIN", "0.25").to_f

    # The CEILING for one call, not a slice of a budget.
    #
    # A flat slice was the wrong shape: any value tight enough to survive a hung
    # call also kills a legitimately slow one. DeadlineTimeout narrows each call
    # to what CallbackBudget says is actually left, so this is only the most a
    # call may ever be given — sized off the WIDEST budget, since a 20s callback
    # must not be capped at a 5s callback's ceiling.
    CALLBACK_TIMEOUT = ENV.fetch("FLUID_CALLBACK_API_TIMEOUT",
                                 CALLBACK_BUDGETS.values.push(CALLBACK_BUDGET).max - CALLBACK_MARGIN).to_f

    CALLBACK_OPEN_TIMEOUT = ENV.fetch("FLUID_CALLBACK_API_OPEN_TIMEOUT", 2).to_i

    # The callback profile keeps its retry, and this is the correction to an
    # earlier commit on this branch that removed it.
    #
    # The reasoning for removing it — "the first attempt only ever raised AT the
    # deadline, so the retry began after Fluid served the cart" — is true of READ
    # timeouts and false of CONNECT ones. CALLBACK_OPEN_TIMEOUT is a separate 2s,
    # so a connect stall raised at 2s and the retry re-issued at ~2.3s with most
    # of the budget unspent. It recovered, routinely.
    #
    # What removing it cost is not a slow callback but a wrong price: a stalled
    # subscriptions GET lands in has_active_subscriptions?'s rescue, which
    # answers false, and should_keep_subscription_prices reads that as "not
    # preferred" and reprices a subscriber's cart to regular.
    #
    # It is registered BEFORE DeadlineTimeout, which makes it the outer
    # middleware: every attempt re-enters the deadline and is re-bounded by what
    # is actually left, so the ladder cannot outlive the budget no matter how
    # many attempts it is given. Once the budget is spent there is nothing left
    # to retry with, and the retry stops mattering on its own.
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
        if remaining
          env.request.timeout = remaining
          # open_timeout is read separately by the adapter (Faraday's
          # request_timeout falls back to :timeout only when :open_timeout is
          # unset, and this profile sets it). Left alone, a late call the
          # deadline has narrowed to the floor could still spend the full
          # CALLBACK_OPEN_TIMEOUT stalling on the socket.
          env.request.open_timeout = [ remaining, CALLBACK_OPEN_TIMEOUT ].min
        end

        @app.call(env)
      end
    end

    def self.create_connection(profile: :job)
      callback = profile == :callback

      Faraday.new(url: Setting.fluid_api.base_url) do |conn|
        conn.request :retry,
                     max: callback ? CALLBACK_RETRIES : 3,
                     interval: callback ? CALLBACK_RETRY_INTERVAL : 0.5,
                     backoff_factor: 2,
                     interval_randomness: 0.2,
                     exceptions: [ Faraday::TimeoutError ]
        # AFTER the retry, so it sits inside it: each attempt gets its own read
        # of what is left rather than reusing the first attempt's timeout.
        conn.use DeadlineTimeout if callback
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
