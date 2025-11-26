class SubscriptionCallbackService
  def initialize(callback_params)
    @callback_params = callback_params
  end

  def handle_subscription_added
    cart = @callback_params[:cart]
    return { success: true } if cart.blank?

    cart_token, cart_items = extract_cart_token_and_items(cart)

    update_cart_metadata(cart_token, { "price_type" => "preferred_customer" })

    if cart_items.any?
      items_data = build_subscription_items_data(cart_items)
      update_cart_items_prices(cart_token, items_data)
    end

    { success: true }
  end

  def handle_subscription_removed
    cart = @callback_params[:cart]
    return { success: true } if cart.blank?

    cart_token, cart_items = extract_cart_token_and_items(cart)

    update_cart_metadata(cart_token, { "price_type" => nil })

    if cart_items.any?
      items_data = build_regular_items_data(cart_items)
      update_cart_items_prices(cart_token, items_data)
    end

    { success: true }
  end

  def handle_item_added
    cart = @callback_params[:cart]
    cart_item = @callback_params[:cart_item]

    return { success: true } if cart.blank? || cart_item.blank?

    price_type = cart.dig("metadata", "price_type")

    if price_type == "preferred_customer"
      subscription_price = cart_item["subscription_price"]

      if subscription_price
        modified_cart_item = cart_item.dup
        modified_cart_item["price"] = subscription_price

        Rails.logger.info "Cart #{cart['cart_token']} item #{cart_item['id']} price changed to subscription price: #{subscription_price}"

        return {
          success: true,
          cart_item: modified_cart_item,
        }
      end
    else
      Rails.logger.info "Cart metadata price_type is not preferred_customer (#{price_type}) - no action needed"
    end

    { success: true }
  end

private

  def find_company
    company_data = @callback_params.dig("cart", "company") || @callback_params.dig(:cart, :company)

    if company_data.present?
      company = Company.find_by(fluid_company_id: company_data["id"])
    end

    company
  rescue StandardError => e
    Rails.logger.error "Error finding company: #{e.message}"
    nil
  end

  def update_cart_metadata(cart_token, metadata)
    return if cart_token.blank?

    company = find_company
    return if company.blank?

    client = FluidClient.new(company.authentication_token)
    return if client.blank?

    client.carts.update_metadata(cart_token, metadata)
  rescue StandardError => e
    Rails.logger.error "Failed to update cart metadata for cart #{cart_token}: #{e.message}"
  end

  def update_cart_items_prices(cart_token, items_data)
    return if cart_token.blank? || items_data.blank?

    company = find_company
    return if company.blank?

    client = FluidClient.new(company.authentication_token)
    return if client.blank?

    payload = { "cart_items" => items_data }

    response = make_cart_items_prices_request(client, cart_token, payload, company.authentication_token)

    response
  rescue StandardError => e
    Rails.logger.error "Failed to update cart items prices for cart #{cart_token}: #{e.message}"
  end

  def build_subscription_items_data(cart_items)
    cart_items.map do |item|
      {
        "id" => item["id"],
        "price" => item["subscription_price"] || item["price"],
      }
    end
  end

  def build_regular_items_data(cart_items)
    cart_items.map do |item|
      {
        "id" => item["id"],
        "price" => item.dig("product", "price") || item["price"],
      }
    end
  end

  def extract_cart_token_and_items(cart)
    cart_token = cart["cart_token"]
    cart_items = cart["items"] || []

    [ cart_token, cart_items ] if cart_token.present? && cart_items.any?
  rescue StandardError => e
    Rails.logger.error "Error extracting cart token and items: #{e.message}"
    nil
  end

  def make_cart_items_prices_request(client, cart_token, payload, auth_token)
    client.class.patch("/api/carts/#{cart_token}/update_cart_items_prices",
                       body: payload.to_json,
                       headers: {
                         "Authorization" => "Bearer #{auth_token}",
                         "Content-Type" => "application/json",
                       })
  end
end
