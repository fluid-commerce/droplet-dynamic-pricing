class Callbacks::SubscriptionRemovedService < Callbacks::BaseService
  def call
    raise CallbackError, "Cart is blank" if cart.blank?

    current_price_type = cart.dig("metadata", "price_type")
    was_preferred = current_price_type == PREFERRED_CUSTOMER_TYPE

    if customer_email.blank?
      if has_another_subscription_in_cart?
        update_cart_metadata({ "price_type" => "preferred_customer" })
        update_cart_items_prices(cart_items_with_subscription_price) if cart_items.any?
        return result_success
      end
      update_cart_metadata({ "price_type" => nil })
      update_cart_items_prices(cart_items_with_regular_price) if cart_items.any?

      if was_preferred
        log_cart_pricing_event(
          event_type: "item_updated",
          preferred_applied: false,
          additional_data: { callback: "subscription_removed", reason: "no_subscriptions_no_email" }
        )
      end
      return result_success
    end

    if should_keep_subscription_prices(customer_email)
      update_cart_metadata({ "price_type" => "preferred_customer" })
      use_subscription_prices = true
    else
      update_cart_metadata({ "price_type" => nil })
      use_subscription_prices = false
    end

    if cart_items.any?
      items_data = use_subscription_prices ? cart_items_with_subscription_price : cart_items_with_regular_price
      update_cart_items_prices(items_data)
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

    if new_customer_subscription_pricing_enabled?
      customer_result = fetch_customer_by_email(customer_email)
      return true if customer_has_no_orders?(customer_result)
    end

    customer_id = get_customer_id_by_email(customer_email)

    if customer_id.present?
      return true if has_subscriptions?(customer_id)
      return true if get_customer_type_from_metafields(customer_id) == PREFERRED_CUSTOMER_TYPE
    end

    has_exigo_autoship_by_email?(customer_email)
  end
end
