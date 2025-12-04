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

  def cart
    @cart ||= callback_params[:cart]
  end

  def cart_token
    @cart_token ||= cart&.dig("cart_token")
  end

  def cart_items
    @cart_items ||= cart&.dig("items") || []
  end

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
    raise CallbackError, "Company is blank" if company.blank?

    FluidClient.new(company.authentication_token)
  end

  def find_company
    company_data = callback_params.dig("cart", "company")
    raise CallbackError, "Company data is blank" if company_data.blank?

    Company.find_by(fluid_company_id: company_data["id"])
  end

  def update_cart_metadata(metadata)
    fluid_client.carts.append_metadata(cart_token, metadata)
  rescue CallbackError => e
    handle_callback_error(e)
  end

  def update_cart_items_prices(items_data)
    raise CallbackError, "Items data is blank" if items_data.blank?
    fluid_client.carts.update_items_prices(cart_token, items_data)
  rescue StandardError => e
    Rails.logger.error "Failed to update cart items prices for cart #{cart_token}: #{e.message}"
  end

  def cart_items_with_subscription_price
    cart_items.map do |item|
      {
        "id" => item["id"],
        "price" => item["subscription_price"] || item["price"],
      }
    end
  end

  def cart_items_with_regular_price
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

    client = fluid_client
    return nil if client.blank?

    Rails.logger.info "Getting cart: #{cart_token}"
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
    response = fluid_client.subscriptions.get_by_customer(customer_id, status: "active")
    subscriptions = response["subscriptions"] || []
    subscriptions.any?
  rescue StandardError => e
    Rails.logger.error "Error checking active subscriptions for customer #{customer_id}: #{e.message}"
    false
  end
end
