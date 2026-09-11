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

    # The retry stays, but OUTSIDE the deadline rather than beside it.
    #
    # The claim that it never worked holds only for READ timeouts: with
    # CALLBACK_TIMEOUT equal to the budget, the first attempt raised at the
    # deadline and the retry began after Fluid had served the cart. It does NOT
    # hold for CONNECT failures — CALLBACK_OPEN_TIMEOUT is a separate 2s, so a
    # connect stall raised at 2s and the retry re-issued at ~2.3s with most of
    # the budget still unspent, and recovered.
    #
    # Dropping it made a single connect stall terminal, and the paths behind it
    # rescue to false: a shopper with a live subscription gets repriced to
    # regular. So it is registered before DeadlineTimeout, which puts it OUTSIDE
    # — every attempt re-enters the middleware and is re-bounded by what is
    # actually left, and once the budget is spent the retry has nothing to spend.
    it "keeps a retry, because a connect stall can fail with budget to spare" do
      handlers = Connections::Fluid.create_connection(profile: :callback).builder.handlers.map(&:name)

      assert(handlers.any? { |name| name.include?("Retry") },
        "a connect stall raises at CALLBACK_OPEN_TIMEOUT with budget left; that is recoverable")
    end

    it "puts the retry outside the deadline, so each attempt is re-bounded" do
      handlers = Connections::Fluid.create_connection(profile: :callback).builder.handlers.map(&:name)
      retry_at = handlers.index { |name| name.include?("Retry") }
      deadline_at = handlers.index { |name| name.include?("DeadlineTimeout") }

      assert_operator retry_at, :<, deadline_at,
        "an attempt that reused the first attempt's timeout could outlive the budget"
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
      CallbackBudget.start!("cart_subscription_removed")
      CallbackBudget.started_at -= 3.0

      assert_in_delta 1.75, run_middleware, 0.05
    end

    # The point of the whole exercise: a call that could still answer in time is
    # never cut short to protect the calls after it.
    it "does not cut a slow call short while the budget can still cover it" do
      CallbackBudget.start!("cart_subscription_removed")

      assert_operator run_middleware, :>, 3.0,
        "an early call must be allowed to take seconds, not a fixed slice"
    end

    # A connect stall is bounded by open_timeout, which Faraday reads separately
    # from :timeout. Leaving it at a flat 2s lets a late call — one the deadline
    # has already narrowed to 0.25s — still spend 2s stalling on the socket.
    it "narrows the connect timeout too, not only the read" do
      env = Faraday::Env.new
      env.request = Faraday::RequestOptions.new
      env.request.timeout = Connections::Fluid::CALLBACK_TIMEOUT
      env.request.open_timeout = Connections::Fluid::CALLBACK_OPEN_TIMEOUT
      CallbackBudget.start!("cart_subscription_removed")
      CallbackBudget.started_at -= 4.9

      Connections::Fluid::DeadlineTimeout.new(->(_) { }).call(env)

      assert_operator env.request.open_timeout, :<=, CallbackBudget::FLOOR
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
