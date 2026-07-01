# frozen_string_literal: true

# Handles Fluid's `cart_customer_detached` callback, fired when a customer is
# unbound from a cart (logout → guest). Rolls back the preferred-customer
# enrichment applied while the customer was attached (STU2-2531).
#
# The payload has no `customer` (the cart is now guest); only
# context.previous_customer_id identifies who was there. Mirrors the
# revert-to-regular path of SubscriptionRemovedService: keep subscription
# pricing only if a subscription item still remains in the cart, otherwise
# restore regular prices and base volumes.
class Callbacks::CartCustomerDetachedService < Callbacks::BaseService
  def call
    raise CallbackError, "Cart is blank" if cart.blank?

    # Enrollment carts are priced by the BP wholesale droplet (STU2-2377).
    return result_success if yield_to_enrollment_wholesale?

    was_preferred = cart.dig("metadata", "price_type") == PREFERRED_CUSTOMER_TYPE

    if has_another_subscription_in_cart?
      update_cart_metadata({ "price_type" => PREFERRED_CUSTOMER_TYPE })
      if cart_items.any?
        update_cart_items_prices(cart_items_with_subscription_price)
        update_cart_items_volumes(cart_items, mode: :subscription)
      end
      return result_success
    end

    update_cart_metadata({ "price_type" => nil })
    if cart_items.any?
      update_cart_items_prices(cart_items_with_regular_price)
      update_cart_items_volumes(cart_items, mode: :regular)
    end

    if was_preferred
      log_cart_pricing_event(
        event_type: "customer_detached",
        preferred_applied: false,
        additional_data: { callback: "cart_customer_detached" }
      )
    end

    result_success
  rescue CallbackError => e
    handle_callback_error(e)
  end
end
