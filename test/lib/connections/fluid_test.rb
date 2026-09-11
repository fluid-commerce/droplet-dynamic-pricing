require "test_helper"

describe Connections::Fluid do
  before do
    Tasks::Settings.create_defaults
  end

  describe "the callback profile" do
    it "is stricter than the default profile" do
      callback = Connections::Fluid.create_connection(profile: :callback).options
      default = Connections::Fluid.create_connection.options

      assert_operator callback.timeout, :<, default.timeout
      assert_operator callback.open_timeout, :<=, default.open_timeout
    end

    # The retry is gone, and it was never doing what it claimed.
    #
    # It was justified as protecting the reads: a failed variant GET made
    # country_safe_price forward the payload price unchecked (STU2-3108). But
    # with a per-call timeout equal to the budget, the first attempt only ever
    # raised AT the deadline, so the retry began after Fluid had already served
    # the cart. It never rescued a call — it spent 5s more answering nobody.
    #
    # Under a deadline the same holds by construction: a timeout means the
    # budget is spent, so there is nothing left to retry INTO. And the STU2-3108
    # exposure it was defending is closed at the source now — country_safe_price
    # refuses an item whose lookup failed instead of forwarding a price it could
    # not check.
    it "does not retry, because a timeout means the budget is already gone" do
      handlers = Connections::Fluid.create_connection(profile: :callback).builder.handlers.map(&:name)

      refute(handlers.any? { |name| name.include?("Retry") },
        "a retry cannot fit inside a budget the first attempt just exhausted")
    end

    # Fluid abandons a synchronous callback at the deadline its DEFINITION
    # declares (Callback::Client#make_requests reads
    # definition.maximum_timeout_in_milliseconds and hands it to Typhoeus).
    # The registration's timeout_in_seconds is never consulted — it appears only
    # in Fluid's client.md. The three callbacks this droplet is alerted on
    # (cart_item_added, cart_subscription_added, cart_subscription_removed) all
    # declare 5000ms, so 5s is the real budget, not the 20s cap Callback
    # validates.
    it "names the deadline Fluid actually enforces" do
      assert_equal 5, Connections::Fluid::CALLBACK_BUDGET
    end

    # The bug behind the TM3 timeout alerts: CALLBACK_TIMEOUT was 5s against a
    # 5s budget, so ONE hung Fluid call consumed the entire deadline on its own
    # — and the retry that followed was 5.25s of work Fluid had already stopped
    # listening for.
    #
    # The fix is not a smaller slice (that kills legitimately slow calls) but a
    # ceiling that leaves the droplet room to answer: every call, even the most
    # generous, has to finish with the margin still unspent.
    it "leaves the droplet room to answer after its most generous call" do
      assert_operator Connections::Fluid::CALLBACK_TIMEOUT + Connections::Fluid::CALLBACK_MARGIN,
                      :<=, Connections::Fluid::CALLBACK_BUDGET,
        "a call allowed the whole budget would answer exactly as Fluid stops listening"
    end

    it "reserves a real margin, not a token one" do
      assert_operator Connections::Fluid::CALLBACK_MARGIN, :>, 0
    end

    it "retries less than background work does" do
      assert_operator Connections::Fluid::CALLBACK_RETRIES, :<, 3
    end
  end

  describe "the deadline middleware" do
    after { CallbackBudget.reset }

    def run_middleware
      env = Faraday::Env.new
      env.request = Faraday::RequestOptions.new
      env.request.timeout = Connections::Fluid::CALLBACK_TIMEOUT
      Connections::Fluid::DeadlineTimeout.new(->(_) { }).call(env)
      env.request.timeout
    end

    it "gives a call what is left of the callback's budget" do
      CallbackBudget.start!
      CallbackBudget.started_at -= 3.0

      assert_in_delta 1.75, run_middleware, 0.05
    end

    # The point of the whole exercise: a call that could still answer in time is
    # never cut short to protect the calls after it.
    it "does not cut a slow call short while the budget can still cover it" do
      CallbackBudget.start!

      assert_operator run_middleware, :>, 3.0,
        "an early call must be allowed to take seconds, not a fixed slice"
    end

    it "leaves background work on its own timeout" do
      CallbackBudget.reset

      assert_equal Connections::Fluid::CALLBACK_TIMEOUT, run_middleware
    end
  end

  describe "the default profile" do
    it "keeps the generous timeout" do
      options = Connections::Fluid.create_connection.options

      assert_equal Connections::Fluid::TIMEOUT, options.timeout
      assert_equal Connections::Fluid::OPEN_TIMEOUT, options.open_timeout
    end

    it "keeps its retries" do
      handlers = Connections::Fluid.create_connection.builder.handlers.map(&:name)

      assert(handlers.any? { |name| name.include?("Retry") }, "background work should still retry")
    end

    it "is what an unrecognised profile falls back to" do
      fallback = Connections::Fluid.create_connection(profile: :nonsense).options

      assert_equal Connections::Fluid::TIMEOUT, fallback.timeout
    end
  end
end
