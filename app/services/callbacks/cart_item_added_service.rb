class Callbacks::CartItemAddedService < Callbacks::BaseService
  def call
    raise CallbackError, "Cart is blank" if cart.blank?
    raise CallbackError, "Cart item is blank" if cart_item.blank?

    # Enrollment carts are priced by the BP wholesale droplet (STU2-2377).
    return result_success if yield_to_enrollment_wholesale?

    current_price_type = cart.dig("metadata", "price_type")

    # Preferred pricing applies when the cart is already stamped, OR when it
    # qualifies now: a subscription line in the cart, or a customer with an
    # active subscription. Re-deriving here means a preferred customer still gets
    # the discount when the stamp is missing on this payload (e.g. the cart was
    # emptied then re-added) without depending on attach/login re-firing (STU2-2531).
    unless current_price_type == PREFERRED_CUSTOMER_TYPE || cart_qualifies_for_preferred_pricing?
      return { success: true, message: "Cart does not have preferred_customer pricing" }
    end

    # Re-affirm the preferred_customer slug on every item-add, not only the
    # first one. The line price and the price_type slug travel on separate,
    # non-atomic channels: the price goes to the cart items (update_cart_items_prices)
    # while the slug lives in cart metadata and the callback response. The old
    # code only wrote the slug when the cart was not yet preferred; a later
    # item-add on an already-preferred cart repriced the line but left the slug
    # unwritten, so any order whose last cart event was an item-add kept the
    # subscription price with a retail price_type. Writing the metadata and
    # returning it here keeps both in step regardless of which cart event is last.
    update_item_to_subscription_price
    update_cart_metadata({ "price_type" => PREFERRED_CUSTOMER_TYPE })

    if current_price_type != PREFERRED_CUSTOMER_TYPE
      log_cart_pricing_event(
        event_type: "item_added",
        preferred_applied: true,
        additional_data: {
          item_id: cart_item["id"],
          subscription_price: cart_item["subscription_price"],
          regular_price: cart_item["price"],
        }
      )
    end

    preferred_pricing_response(message: "Cart item updated to subscription price successfully")
  rescue CallbackError => e
    handle_callback_error(e)
  rescue StandardError => e
    Rails.logger.error "Unexpected error in CartItemAddedService: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    report_exception(e)
    { success: false, error: "unexpected_error", message: "An unexpected error occurred" }
  end
end
