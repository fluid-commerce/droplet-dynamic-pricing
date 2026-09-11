require "test_helper"

# The callback-timing line is the only per-request measurement of the work a
# shopper's add-to-cart is blocked on. It reported a total and nothing else, so
# "the callback took 3.4s" could not be turned into "and 3.1s of it was Fluid,
# over 14 calls" without guessing.
class Callbacks::TimingLogTest < ActionDispatch::IntegrationTest
  fixtures(:companies)

  def cart_data
    {
      "cart_token" => "ct_timing",
      "company" => { "id" => companies(:acme).fluid_company_id },
      "items" => [],
    }
  end

  def capture_timing_line
    io = StringIO.new
    original = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(io)
    yield
    io.string[/\[DynamicPricing\] marker=callback-timing.*/]
  ensure
    Rails.logger = original
  end

  # Without this the deadline never starts, CallbackBudget.remaining stays nil,
  # and every Fluid call silently falls back to the connection ceiling — the
  # flat timeout the deadline exists to replace.
  test "starts the deadline so Fluid calls are bounded by what is left of it" do
    seen = nil

    Callbacks::CartItemAddedService.stub(:call, ->(*) {
      seen = CallbackBudget.remaining
      { success: true }
    }) do
      post "/callbacks/cart_item_added", params: { cart: cart_data, cart_item: { "id" => 1 } }, as: :json
    end

    refute_nil seen, "the callback request must put a deadline on the work it does"
    assert_in_delta 5 - Connections::Fluid::CALLBACK_MARGIN, seen, 0.1
  end

  # The controller class name is NOT Fluid's definition name — this droplet
  # answers cart_subscription_removed at /callbacks/subscription_removed — and
  # the budget is keyed by the definition, so resolving it off the class would
  # silently miss and hand every such callback the fallback budget.
  test "resolves the budget by Fluid's definition name, not the controller's" do
    seen = nil

    Callbacks::SubscriptionRemovedService.stub(:call, ->(*) {
      seen = CallbackBudget.budget
      { success: true }
    }) do
      post "/callbacks/subscription_removed", params: { cart: cart_data }, as: :json
    end

    assert_equal 5, seen
  end

  test "gives a 20s callback its real budget" do
    seen = nil

    Callbacks::CustomerLoggedInService.stub(:call, ->(*) {
      seen = CallbackBudget.budget
      { success: true }
    }) do
      post "/callbacks/customer_logged_in",
           params: { cart: cart_data.merge("email" => "s@example.com") }, as: :json
    end

    assert_equal 20, seen,
      "cart_customer_logged_in omits maximum_timeout_in_milliseconds, so Fluid waits 20s"
  end

  test "reports the outbound Fluid share alongside the total" do
    line = capture_timing_line do
      Callbacks::CartItemAddedService.stub(:call, ->(*) {
        CallbackHttpTally.record(0.120)
        CallbackHttpTally.record(0.080)
        { success: true }
      }) do
        post "/callbacks/cart_item_added", params: { cart: cart_data, cart_item: { "id" => 1 } }, as: :json
      end
    end

    refute_nil line, "the callback should still log its timing line"
    assert_match(/fluid_calls=2/, line)
    assert_match(/fluid_ms=200/, line)
  end
end
