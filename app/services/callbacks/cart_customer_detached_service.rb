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

    # The cart is already paid for (or the order already exists): nothing left to
    # price, and writing now desyncs the order total from the captured amount
    # (CURRENT-3361).
    return result_success if cart_settled?

    # Enrollment carts and yoli-promos WHOLESALE-unlock carts are priced by the
    # BP wholesale droplet (STU2-2377, STU2-2964).
    return result_success if yield_to_enrollment_wholesale? || price_type_wholesale?

    was_preferred = cart.dig("metadata", "price_type") == PREFERRED_CUSTOMER_TYPE

    # The same rule as everywhere else, evaluated on a cart that no longer has a
    # bound customer: with customer_id nil the customer half of
    # cart_qualifies_for_preferred_pricing? has no subject, so a line in the cart is
    # all that can justify preferred here. Spelled out rather than delegated,
    # because the Exigo half of that predicate keys off the cart's EMAIL and is not
    # gated on a bound customer — delegating would have let a logged-out cart keep
    # subscription pricing on Rain and Yoli, which is not the rule.
    if has_another_subscription_in_cart?
      update_cart_metadata({ "price_type" => PREFERRED_CUSTOMER_TYPE })
      if cart_items.any?
        update_cart_items_prices(cart_items_with_subscription_price)
        update_cart_items_volumes(cart_items, mode: :subscription)
      end
      return result_success
    end

    # Only roll back pricing this droplet actually applied. An unstamped cart was
    # never put on preferred pricing by us, so rewriting every line to
    # product.price on a mere logout would clobber whatever else set those prices
    # (another droplet, a promo) — and was one half of the oscillating pair in
    # CURRENT-3361.
    return result_success unless was_preferred

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
