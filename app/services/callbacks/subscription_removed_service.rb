class Callbacks::SubscriptionRemovedService < Callbacks::BaseService
  def call
    cart = @callback_params[:cart]
    return { success: true } if cart.blank?

    cart_token, cart_items = extract_cart_token_and_items(cart)
    customer_email = cart["email"]

    if customer_email.blank?
      should_keep_subscription_prices = false
    else
      customer_id = get_customer_id_by_email(customer_email)

      if customer_id.blank?
        should_keep_subscription_prices = false
      else
        should_keep_subscription_prices = should_maintain_subscription_pricing?(customer_id)
      end
    end

    if should_keep_subscription_prices
      update_cart_metadata(cart_token, { "price_type" => "preferred_customer" })
      use_subscription_prices = true
    else
      update_cart_metadata(cart_token, { "price_type" => nil })
      use_subscription_prices = false
    end

    if cart_items.any?
      all_items_data = cart_items.map do |item|
        price = if use_subscription_prices
          item["subscription_price"] || item["price"]
        else
          item.dig("product", "price") || item["price"]
        end

        {
          "id" => item["id"],
          "price" => price,
        }
      end

      update_cart_items_prices(cart_token, all_items_data)
    end

    { success: true }
  end

private

  def should_maintain_subscription_pricing?(customer_id)
    result = has_active_subscriptions?(customer_id)
    result
  end

  def get_customer_id_by_email(email)
    return nil if email.blank?

    company = find_company
    return nil if company.blank?

    client = FluidClient.new(company.authentication_token)
    return nil if client.blank?

    response = client.customers.get(email: email)
    customers = response["customers"] || []

    customers.any? ? customers.first["id"] : nil
  rescue StandardError
    nil
  end
end
