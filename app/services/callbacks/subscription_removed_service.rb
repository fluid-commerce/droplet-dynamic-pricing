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

    if customer_email.blank?
      if has_another_subscription_in_cart?
        update_cart_metadata({ "price_type" => "preferred_customer" })
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
          event_type: "item_updated",
          preferred_applied: false,
          additional_data: { callback: "subscription_removed", reason: "no_subscriptions_no_email" }
        )
      end
      return result_success
    end

    keep = should_keep_subscription_prices(customer_email)

    # `keep == false` means either "not preferred" or "we could not tell": every
    # lookup behind should_keep_subscription_prices rescues to false and flags
    # the failure. Only the first justifies stripping the discount off every
    # line — CustomerLoggedInService has guarded the same branch since
    # CURRENT-3361, and this service was missing it, so a single failed Fluid
    # call repriced a live subscriber's cart to regular.
    #
    # Leaving the cart untouched is the safe end: it keeps whatever it already
    # had, and the next callback re-derives the answer with a working lookup.
    if !keep && was_preferred && preferred_lookup_failed?
      Rails.logger.warn(
        "[DynamicPricing] Not stripping preferred pricing on cart #{cart_token}: " \
        "a preferred lookup failed, so 'not preferred' is unproven"
      )
      return result_success
    end

    if keep
      update_cart_metadata({ "price_type" => "preferred_customer" })
      use_subscription_prices = true
    else
      update_cart_metadata({ "price_type" => nil })
      use_subscription_prices = false
    end

    if cart_items.any?
      items_data = use_subscription_prices ? cart_items_with_subscription_price : cart_items_with_regular_price
      update_cart_items_prices(items_data)
      update_cart_items_volumes(cart_items, mode: use_subscription_prices ? :subscription : :regular)
    end

    is_now_preferred = use_subscription_prices
    if was_preferred != is_now_preferred
      log_cart_pricing_event(
        event_type: "item_updated",
        preferred_applied: is_now_preferred,
        additional_data: {
          callback: "subscription_removed",
          reason: is_now_preferred ? "should_keep_preferred" : "removed_preferred",
        }
      )
    end

    result_success
  rescue CallbackError => e
    handle_callback_error(e)
  end

private

  def should_keep_subscription_prices(customer_email)
    return false if customer_email.blank?

    return true if has_another_subscription_in_cart?

    return false unless customer_logged_in?

    # customer_logged_in? IS cart_customer_id.present?, so the id is already in
    # hand; looking it up by email spent a Fluid GET to re-derive it on the
    # slowest callback this droplet serves. No `||` fallback: the guard above
    # makes cart_customer_id present by construction, so one would be dead code
    # describing a call this path cannot make.
    customer_id = cart_customer_id

    if customer_id.present?
      return true if has_active_subscriptions?(customer_id)
      return true if get_customer_type_from_metafields(customer_id) == PREFERRED_CUSTOMER_TYPE
    end

    exigo_preferred_by_email?(customer_email)
  end
end
