class Callbacks::SubscriptionAddedService < Callbacks::BaseService
  def call
    raise CallbackError, "Cart is blank" if cart.blank?

    current_price_type = cart.dig("metadata", "price_type")

    update_cart_metadata({ "price_type" => "preferred_customer" })
    update_cart_items_prices(cart_items_with_subscription_price) if cart_items.any?

    # Only log if there's a state change (wasn't preferred before)
    if current_price_type != PREFERRED_CUSTOMER_TYPE
      log_cart_pricing_event(
        event_type: "item_added",
        preferred_applied: true,
        additional_data: {
          callback: "subscription_added",
          items_updated: cart_items.count,
        }
      )
    end

    result_success
  rescue CallbackError => e
    handle_callback_error(e)
  end
end
