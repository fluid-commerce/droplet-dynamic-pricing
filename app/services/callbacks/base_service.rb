class Callbacks::BaseService
  def initialize(callback_params)
    @callback_params = callback_params
  end

  def self.call(callback_params)
    new(callback_params).call
  end

  def call
    raise NotImplementedError, "Subclasses must implement call method"
  end

protected

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

  def make_cart_items_prices_request(client, cart_token, payload, auth_token)
    client.class.patch("/api/carts/#{cart_token}/update_cart_items_prices",
                       body: payload.to_json,
                       headers: {
                         "Authorization" => "Bearer #{auth_token}",
                         "Content-Type" => "application/json",
                       })
  end

  def get_customer_type_by_email(email)
    company = find_company
    return nil if company.blank?

    client = FluidClient.new(company.authentication_token)
    return if client.blank?

    response = client.customers.get(email: email)
    customers = response["customers"] || []

    if customers.any?
      customer = customers.first
      customer.dig("metadata", "customer_type")
    else
      nil
    end
  rescue StandardError => e
    Rails.logger.error "Failed to get customer type for email #{email}: #{e.message}"
    nil
  end
end
