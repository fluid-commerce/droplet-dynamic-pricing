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

private

  attr_reader :callback_params

  def result_success
    { success: true }
  end

  def handle_callback_error(error)
    service_name = self.class.name.demodulize
    Rails.logger.error "[#{service_name}] #{error.message}"

    { success: false, message: error.message }
  end

  def fluid_client
    @fluid_client ||= initialize_fluid_client
  end

  def initialize_fluid_client
    company = find_company
    return nil if company.blank?

    FluidClient.new(company.authentication_token)
  end

  def find_company
    company_data = callback_params.dig("cart", "company")

    return nil unless company_data.present?

    Company.find_by(fluid_company_id: company_data["id"])
  rescue StandardError => e
    Rails.logger.error "Error finding company: #{e.message}"
    nil
  end

  def update_cart_metadata(cart_token, metadata)
    return if cart_token.blank?

    client = fluid_client
    return if client.blank?

    client.carts.append_metadata(cart_token, metadata)
  rescue StandardError => e
    Rails.logger.error "Failed to update cart metadata for cart #{cart_token}: #{e.message}"
  end

  def update_cart_items_prices(cart_token, items_data)
    return if cart_token.blank? || items_data.blank?

    client = fluid_client
    return if client.blank?

    company = find_company
    return if company.blank?

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
    response = client.patch("/api/carts/#{cart_token}/update_cart_items_prices", body: payload)

    response
  rescue StandardError => e
    Rails.logger.error "Error in make_cart_items_prices_request: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    raise e
  end

  def get_cart(cart_token)
    return nil if cart_token.blank?

    client = fluid_client
    return nil if client.blank?

    client.carts.get(cart_token)
  rescue StandardError => e
    Rails.logger.error "Failed to get cart #{cart_token}: #{e.message}"
    nil
  end

  def get_customer_type_by_email(email)
    client = fluid_client
    return nil if client.blank?

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


  def has_active_subscriptions?(customer_id)
    return false if customer_id.blank?

    client = fluid_client
    return false if client.blank?

    response = client.subscriptions.get_by_customer(customer_id, status: "active")
    subscriptions = response["subscriptions"] || []
    subscriptions.any?
  rescue StandardError => e
    Rails.logger.error "Error checking active subscriptions for customer #{customer_id}: #{e.message}"
    false
  end

  def make_update_totals_request(client, cart_token, payload, auth_token)
    response = client.patch("/api/carts/#{cart_token}/update_totals", body: payload)

    response
  rescue StandardError => e
    Rails.logger.error "Error in make_update_totals_request: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    raise e
  end

  def extract_cart_token_and_items(cart)
    cart_token = cart["cart_token"]
    cart_items = cart["items"] || []
    [ cart_token, cart_items ]
  end
end
