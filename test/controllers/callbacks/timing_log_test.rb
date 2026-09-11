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
    assert_operator seen, :<=, Connections::Fluid::CALLBACK_BUDGET
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
