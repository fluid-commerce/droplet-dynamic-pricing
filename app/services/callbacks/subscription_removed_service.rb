class Callbacks::SubscriptionRemovedService < Callbacks::BaseService
  def call
    raise CallbackError, "Cart is blank" if cart.blank?

    customer_email = cart["email"]
    should_keep_subscription_prices = determine_subscription_pricing_status(customer_email)

    if should_keep_subscription_prices
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

  def determine_subscription_pricing_status(customer_email)
    return false if customer_email.blank?

    customer_id = get_customer_id_by_email(customer_email)
    return false if customer_id.blank?

    should_maintain_subscription_pricing?(customer_id)
  end

  def should_maintain_subscription_pricing?(customer_id)
    has_active = has_active_subscriptions?(customer_id)
    has_another = has_another_subscription_in_cart?(customer_id)

    has_active || has_another
  end

  def has_another_subscription_in_cart?(_customer_id)
    active_subscription_count = cart_items.count { |item| item["subscription"] == true }

    active_subscription_count >= 1
  end

  def get_customer_id_by_email(email)
    return nil if email.blank?

    client = fluid_client
    return nil if client.blank?

    response = client.customers.get(email: email)
    customers = response["customers"] || []

    customers.any? ? customers.first["id"] : nil
  rescue StandardError => e
    Rails.logger.error "Failed to get customer ID by email #{email}: #{e.message}"
    nil
  end
end
