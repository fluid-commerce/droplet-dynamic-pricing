class Callbacks::SubscriptionAddedService < Callbacks::BaseService
  def call
    raise CallbackError, "Cart is blank" if cart.blank?

    # Enrollment carts are priced by the BP wholesale droplet (STU2-2377).
    return result_success if yield_to_enrollment_wholesale?

    current_price_type = cart.dig("metadata", "price_type")

    update_cart_metadata({ "price_type" => "preferred_customer" })
    if cart_items.any?
      update_cart_items_prices(cart_items_with_subscription_price)
      update_cart_items_volumes(cart_items, mode: :subscription)
    end

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
