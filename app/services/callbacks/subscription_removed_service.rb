class Callbacks::SubscriptionRemovedService < Callbacks::BaseService
  def call
    cart = callback_params[:cart]
    return { success: true } if cart.blank?

    cart_token, cart_items = extract_cart_token_and_items(cart)
    customer_email = cart["email"]

    should_keep_subscription_prices = determine_subscription_pricing_status(customer_email)

    if should_keep_subscription_prices
      update_cart_metadata(cart_token, { "price_type" => "preferred_customer" })
      use_subscription_prices = true
    else
      update_cart_metadata(cart_token, { "price_type" => nil })
      use_subscription_prices = false
    end

    if cart_items.any?
      all_items_data = build_items_data(cart_items, use_subscription_prices)
      update_cart_items_prices(cart_token, all_items_data)
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
    has_active_subscriptions?(customer_id)
  end

  def build_items_data(cart_items, use_subscription_prices)
    if use_subscription_prices
      build_subscription_items_data(cart_items)
    else
      build_regular_items_data(cart_items)
    end
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
