class Callbacks::SubscriptionRemovedService < Callbacks::BaseService
  def call
    raise CallbackError, "Cart is blank" if cart.blank?

    if customer_email.blank?
      if has_another_subscription_in_cart?
        update_cart_metadata({ "price_type" => "preferred_customer" })
        update_cart_items_prices(cart_items_with_subscription_price) if cart_items.any?
        return result_success
      end
      update_cart_metadata({ "price_type" => nil })
      update_cart_items_prices(cart_items_with_regular_price) if cart_items.any?
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

    result_success
  rescue CallbackError => e
    handle_callback_error(e)
  end

private

  def should_keep_subscription_prices(customer_email)
    return false if customer_email.blank?

    customer_id = get_customer_id_by_email(customer_email)
    return false if customer_id.blank?

    has_subscriptions?(customer_id)
  end
end
