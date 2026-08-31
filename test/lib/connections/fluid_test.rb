require "test_helper"

describe Connections::Fluid do
  before do
    Tasks::Settings.create_defaults
  end

  # The cap Fluid enforces on us, read off the model rather than hardcoded so
  # this test follows the cap if it ever moves.
  def callback_budget
    Callback.validators_on(:timeout_in_seconds)
            .filter_map { |validator| validator.options[:less_than_or_equal_to] }
            .first
  end

  describe "the callback profile" do
    it "keeps a single call inside the budget Callback allows" do
      refute_nil callback_budget, "Callback should still cap timeout_in_seconds"

      timeout = Connections::Fluid.create_connection(profile: :callback).options.timeout

      assert_operator timeout, :<, callback_budget
    end

    it "is stricter than the default profile" do
      callback = Connections::Fluid.create_connection(profile: :callback).options
      default = Connections::Fluid.create_connection.options

      assert_operator callback.timeout, :<, default.timeout
      assert_operator callback.open_timeout, :<=, default.open_timeout
    end

    # The only retried exception is Faraday::TimeoutError, so here the ladder can
    # only fire once the budget is already gone.
    it "carries no retry middleware" do
      handlers = Connections::Fluid.create_connection(profile: :callback).builder.handlers.map(&:name)

      refute(handlers.any? { |name| name.include?("Retry") }, "the callback profile must not retry")
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
