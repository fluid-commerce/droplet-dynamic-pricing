class Callbacks::SubscriptionRemovedService < Callbacks::BaseService
  def call
    raise CallbackError, "Cart is blank" if cart.blank?

    # The cart is already paid for (or the order already exists): nothing left to
    # price, and writing now desyncs the order total from the captured amount
    # (CURRENT-3361).
    return result_success if cart_settled?

    # Enrollment carts and yoli-promos WHOLESALE-unlock carts are priced by the
    # BP wholesale droplet (STU2-2377, STU2-2964).
    return result_success if yield_to_enrollment_wholesale? || price_type_wholesale?

    current_price_type = cart.dig("metadata", "price_type")
    was_preferred = current_price_type == PREFERRED_CUSTOMER_TYPE

    # One rule, same as every other callback. This used to carry its own ladder —
    # a separate branch for a blank email, then metafield, then subscriptions,
    # then Exigo — which is how it could answer differently from attach about the
    # same cart (CURRENT-3361).
    is_now_preferred = cart_qualifies_for_preferred_pricing?

    # Never revert on the strength of a lookup that errored out.
    #
    # Unlike the logout and verify-email paths, this one does NOT also require the
    # cart to be stamped: the trigger is a subscription line being removed from
    # THIS cart, so the prices on it were almost certainly ours to correct. Those
    # other two fire for reasons unrelated to pricing, which is why they insist on
    # the stamp before rewriting a line (CURRENT-3361).
    return result_success if !is_now_preferred && preferred_lookup_failed?

    update_cart_metadata({ "price_type" => is_now_preferred ? PREFERRED_CUSTOMER_TYPE : nil })

    if cart_items.any?
      items_data = is_now_preferred ? cart_items_with_subscription_price : cart_items_with_regular_price
      update_cart_items_prices(items_data)
      update_cart_items_volumes(cart_items, mode: is_now_preferred ? :subscription : :regular)
    end

    if was_preferred != is_now_preferred
      log_cart_pricing_event(
        event_type: "item_updated",
        preferred_applied: is_now_preferred,
        additional_data: {
          callback: "subscription_removed",
          reason: is_now_preferred ? "still_qualifies" : "no_longer_qualifies",
        }
      )
    end

    result_success
  rescue CallbackError => e
    handle_callback_error(e)
  end
end
