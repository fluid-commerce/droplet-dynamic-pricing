require "test_helper"

class CartPricingEventTest < ActiveSupport::TestCase
  fixtures(:companies)

  # These event_types are emitted by the callback services and MUST be accepted
  # by the model. Historically the enum only listed the cart_*/item_* types, so
  # `customer_logged_in` (from CustomerLoggedInService / CartCustomerAttachedService)
  # and `customer_detached` (from CartCustomerDetachedService) raised
  # ArgumentError, which log_cart_pricing_event swallowed — so those events were
  # never recorded and the failure was invisible (STU2-2531).
  VALID_EVENT_TYPES = %w[
    cart_created
    item_added
    item_updated
    customer_logged_in
    customer_detached
  ].freeze

  test "accepts every event_type emitted by the callback services" do
    company = companies(:acme)

    VALID_EVENT_TYPES.each do |event_type|
      event = CartPricingEvent.create!(
        company: company,
        cart_id: 721786,
        email: "matias@fluid.app",
        event_type: event_type,
        preferred_pricing_applied: true,
        items_count: 1,
        cart_total: 55.97,
        metadata: {}
      )

      assert event.persisted?, "expected event_type '#{event_type}' to persist"
      assert_equal event_type, event.event_type
    end
  end
end
