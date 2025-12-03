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
  rescue CallbackError => e
    handle_callback_error(e)
  end

  def find_company
    company_data = callback_params.dig("cart", "company")
    raise CallbackError, "Company data is blank" if company_data.blank?

    Company.find_by(fluid_company_id: company_data["id"])
  rescue CallbackError => e
    handle_callback_error(e)
  end

  def update_cart_metadata(metadata)
    client = fluid_client
    raise CallbackError, "Fluid client is blank" if client.blank?

    client.carts.append_metadata(cart_token, metadata)
  rescue CallbackError => e
    handle_callback_error(e)
  end

  def update_cart_items_prices(items_data)
    raise CallbackError, "Items data is blank" if items_data.blank?

    client = fluid_client
    raise CallbackError, "Fluid client is blank" if client.blank?

    client.carts.update_items_prices(cart_token, items_data)
  rescue StandardError => e
    Rails.logger.error "Failed to update cart items prices for cart #{cart_token}: #{e.message}"
  end

  def build_subscription_items_data
    cart_items.map do |item|
      {
        "id" => item["id"],
        "price" => item["subscription_price"] || item["price"],
      }
    end
  end

  def build_regular_items_data
    cart_items.map do |item|
      {
        "id" => item["id"],
        "price" => item.dig("product", "price") || item["price"],
      }
    end
  end

  def has_active_subscriptions?(customer_id)
    raise CallbackError, "Customer id is blank" if customer_id.blank?

    client = fluid_client
    raise CallbackError, "Fluid client is blank" if client.blank?

    response = client.subscriptions.get_by_customer(customer_id, status: "active")
    subscriptions = response["subscriptions"] || []
    subscriptions.any?
  rescue StandardError => e
    Rails.logger.error "Error checking active subscriptions for customer #{customer_id}: #{e.message}"
    false
  end
end
