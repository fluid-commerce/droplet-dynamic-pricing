class Callbacks::BaseService
  PREFERRED_CUSTOMER_TYPE = "preferred_customer"

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

  def log_and_return(log_message, success: true, message: nil, error: nil)
    service_name = self.class.name.demodulize
    Rails.logger.debug "[#{service_name}] #{log_message}"

    result = { success: success }
    result[:message] = message || log_message
    result[:error] = error if error

    result
  end

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

    client.carts.append_metadata(cart_token, metadata)
  rescue StandardError => e
    Rails.logger.error "Failed to update cart metadata for cart #{cart_token}: #{e.message}"
  end

  def update_cart_items_prices(cart_token, items_data)
    return if cart_token.blank? || items_data.blank?

    company = find_company
    return if company.blank?

    client = FluidClient.new(company.authentication_token)
    return if client.blank?
    Rails.logger.info "Updating cart items prices: #{items_data}"
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
    Rails.logger.info "Making request to update cart items prices: #{payload}"
    response = client.patch("/api/carts/#{cart_token}/update_cart_items_prices", body: payload)

    response
  rescue StandardError => e
    Rails.logger.error "Error in make_cart_items_prices_request: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    raise e
  end

  def get_cart(cart_token)
    return nil if cart_token.blank?

    company = find_company
    return nil if company.blank?

    client = FluidClient.new(company.authentication_token)
    return nil if client.blank?
    Rails.logger.info "Getting cart: #{cart_token}"
    client.carts.get(cart_token)
  rescue StandardError => e
    Rails.logger.error "Failed to get cart #{cart_token}: #{e.message}"
    nil
  end

  def get_customer_by_email(email)
    company = find_company
    return nil if company.blank?

    client = FluidClient.new(company.authentication_token)
    return nil if client.blank?

    escaped_email = CGI.escape(email.to_s)
    search_query = "search_query=#{escaped_email}"

    response = client.get("/api/customers?#{search_query}")
    customers = response["customers"] || []

    customers.first
  rescue StandardError => e
    Rails.logger.error "Failed to get customer by email #{email}: #{e.message}"
    nil
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

  def update_cart_totals(cart_token, cart_items, use_subscription_prices: false)
    return if cart_token.blank? || cart_items.blank?

    company = find_company
    return if company.blank?

    client = FluidClient.new(company.authentication_token)
    return if client.blank?

    total_amount = calculate_total_amount(cart_items, use_subscription_prices)
    payload = { "amount_total" => total_amount }
    Rails.logger.info "amount_total: #{total_amount}, Payload: #{payload}"

    make_update_totals_request(client, cart_token, payload, company.authentication_token)
  rescue StandardError => e
    Rails.logger.error "Failed to update cart totals for cart #{cart_token}: #{e.message}"
  end

  def calculate_total_amount(cart_items, use_subscription_prices)
    cart_items.sum do |item|
      quantity = item["quantity"] || 1
      price = if use_subscription_prices
        item["subscription_price"] || item["price"]
      else
        item.dig("product", "price") || item["price"]
      end
      Rails.logger.info "price: #{price}, quantity: #{quantity}"
      price.to_f * quantity.to_i
    end
  end

  def make_update_totals_request(client, cart_token, payload, auth_token)
    response = client.patch("/api/carts/#{cart_token}/update_totals", body: payload)

    response
  rescue StandardError => e
    Rails.logger.error "Error in make_update_totals_request: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    raise e
  end
end
