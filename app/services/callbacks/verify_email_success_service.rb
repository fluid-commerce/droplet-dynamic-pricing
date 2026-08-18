# frozen_string_literal: true

# Handles Fluid's `verify_email_success` callback.
#
# This service used to decide twice in one request: clean_cart_metadata_before_update
# walked its own ladder (subscription line, then a customer lookup, then
# subscriptions, then Exigo) and reverted the cart, after which
# fetch_and_validate_customer_type consulted the customer_type metafield and
# re-applied preferred. On a lapsed subscriber whose metafield still said
# preferred_customer, that wrote 61.00 and then 55.00 to the same line in the same
# request — an oscillation needing no second callback at all (CURRENT-3361).
#
# It now decides once, from the same rule as every other callback.
class Callbacks::VerifyEmailSuccessService < Callbacks::BaseService
  def call
    raise CallbackError, "Cart is blank" if cart.blank?
    raise CallbackError, "Missing email" if customer_email.blank?

    # The cart is already paid for (or the order already exists): nothing left to
    # price, and writing now desyncs the order total from the captured amount
    # (CURRENT-3361).
    return result_success if cart_settled?

    # Enrollment carts and yoli-promos WHOLESALE-unlock carts are priced by the
    # BP wholesale droplet (STU2-2377, STU2-2964).
    return result_success if yield_to_enrollment_wholesale? || price_type_wholesale?

    was_preferred = cart.dig("metadata", "price_type") == PREFERRED_CUSTOMER_TYPE
    is_preferred = cart_qualifies_for_preferred_pricing?(require_bound_customer: true)

    # Never revert on the strength of a lookup that errored out, and never revert a
    # cart this droplet did not price.
    return result_success if !is_preferred && (preferred_lookup_failed? || !was_preferred)

    apply_pricing(is_preferred)

    if was_preferred != is_preferred
      log_cart_pricing_event(
        event_type: "item_updated",
        preferred_applied: is_preferred,
        additional_data: { callback: "verify_email_success", email: customer_email }
      )
    end

    result_success
  rescue CallbackError => e
    handle_callback_error(e)
  end

private

  def apply_pricing(is_preferred)
    update_cart_metadata({ "price_type" => is_preferred ? PREFERRED_CUSTOMER_TYPE : nil })
    return unless cart_items.any?

    items = is_preferred ? cart_items_with_subscription_price : cart_items_with_regular_price
    update_cart_items_prices(items)
    update_cart_items_volumes(cart_items, mode: is_preferred ? :subscription : :regular)
  end
end
