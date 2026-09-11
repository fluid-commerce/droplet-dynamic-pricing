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

    # It must KEEP a retry. faraday-retry only retries idempotent methods, so the
    # ladder applies to the reads — and a failed variant GET makes
    # country_safe_price forward the payload price unchecked (STU2-3108). Removing
    # the retry would trade a slow callback for a wrong price.
    it "keeps a retry, because the reads are what it protects" do
      handlers = Connections::Fluid.create_connection(profile: :callback).builder.handlers.map(&:name)

      assert(handlers.any? { |name| name.include?("Retry") }, "the callback profile must still retry reads")
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
    it "fits its whole ladder inside the deadline Fluid enforces" do
      attempts = Connections::Fluid::CALLBACK_RETRIES + 1
      worst_case = (attempts * Connections::Fluid::CALLBACK_TIMEOUT) +
                   (Connections::Fluid::CALLBACK_RETRIES * Connections::Fluid::CALLBACK_RETRY_INTERVAL)

      assert_operator worst_case, :<, Connections::Fluid::CALLBACK_BUDGET,
        "every attempt plus every backoff has to fit in the #{Connections::Fluid::CALLBACK_BUDGET}s " \
        "deadline Fluid abandons the callback at"
    end

    # A single attempt must leave room for the rest of the callback's work, not
    # just for itself: subscription_removed measures p95 3.47s in production
    # across a dozen-odd sequential calls. A per-call timeout equal to the whole
    # budget cannot be survived by anything downstream of it.
    it "keeps one attempt to a fraction of the budget" do
      assert_operator Connections::Fluid::CALLBACK_TIMEOUT, :<=, Connections::Fluid::CALLBACK_BUDGET / 2.0,
        "one attempt must not be able to spend half the budget"
    end

    it "retries less than background work does" do
      assert_operator Connections::Fluid::CALLBACK_RETRIES, :<, 3
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
