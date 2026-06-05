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

  def customer_email
    @customer_email ||= cart&.dig("email")
  end

  def cart_customer_id
    @cart_customer_id ||= cart&.dig("customer_id")
  end

  def customer_logged_in?
    cart_customer_id.present?
  end

  def cart_token
    @cart_token ||= cart&.dig("cart_token")
  end

  def cart_items
    @cart_items ||= cart&.dig("items") || []
  end

  # BP enrollment carts are priced by the yoli-promos droplet (wholesale), which
  # takes precedence. Dynamic pricing must yield on those carts to avoid both
  # droplets fighting over the same items (STU2-2377).
  #
  # Only companies that actually run yoli-promos (i.e. Yoli) should yield — for
  # everyone else, yielding would strip preferred-customer pricing from
  # enrollment carts. So the skip is gated behind a per-company toggle
  # (Integration Settings), off by default.
  def yield_to_enrollment_wholesale?
    enrollment_cart? && company_yields_to_enrollment_wholesale?
  end

  def enrollment_cart?
    cart&.dig("type") == "enrollment" ||
      cart_items.any? { |item| item["enrollment_pack_id"].present? }
  end

  def company_yields_to_enrollment_wholesale?
    company = find_company
    return false if company.blank?

    company.integration_setting&.yield_to_enrollment_wholesale? || false
  rescue CallbackError
    false
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
    # Use the `cart` accessor (reads callback_params[:cart]) rather than
    # callback_params.dig("cart", ...) so this works whether the cart key is a
    # symbol (plain hash, e.g. in tests) or a string (HashWithIndifferentAccess
    # from the controller in production).
    company_data = cart&.dig("company")
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

  def get_customer_id_by_email(email)
    return nil if email.blank?

    client = fluid_client
    response = client.customers.get(email: email)
    customers = response["customers"] || []

    customers.any? ? customers.first["id"] : nil
  rescue StandardError => e
    Rails.logger.error "Failed to get customer ID by email #{email}: #{e.message}"
    nil
  end

  def get_customer_type_from_metafields(customer_id)
    metafield = fluid_client.metafields.get_by_key(
      resource_type: "customer",
      resource_id: customer_id,
      key: "customer_type"
    )
    metafield&.dig("value", "customer_type") || metafield&.dig(:value, :customer_type)
  rescue StandardError
    nil
  end

  def fetch_customer_by_email(email)
    response = fluid_client.customers.get(email: email)
    customers = response["customers"] || []

    customer = customers.find { |c| c["email"]&.downcase == email.downcase }

    { success: true, data: customer }
  rescue StandardError
    { success: false, error: "customer_lookup_failed", message: "Unable to fetch customer data" }
  end

  def has_subscriptions?(customer_id)
    has_active = has_active_subscriptions?(customer_id)
    has_another = has_another_subscription_in_cart?

    has_active || has_another
  end

  def has_another_subscription_in_cart?
    active_subscription_count = cart_items.count { |item| item["subscription"] == true }

    active_subscription_count >= 1
  end

  def has_active_subscriptions?(customer_id)
    response = fluid_client.subscriptions.get_by_customer(customer_id, status: "active")
    subscriptions = response["subscriptions"] || []
    subscriptions.any?
  rescue StandardError => e
    Rails.logger.error "Error checking active subscriptions for customer #{customer_id}: #{e.message}"
    false
  end

  def has_exigo_autoship_by_email?(email)
    return false unless exigo_integration_enabled?
    return false if email.blank?

    exigo_client.customer_has_active_autoship_by_email?(email)
  rescue StandardError => e
    Rails.logger.error "Error checking Exigo autoship for email #{email}: #{e.message}"
    false
  end

  def exigo_integration_enabled?
    company = find_company
    return false if company.blank?

    company.integration_setting&.exigo_enabled? || false
  end

  def exigo_client
    @exigo_client ||= initialize_exigo_client
  end

  def initialize_exigo_client
    company = find_company
    raise CallbackError, "Company is blank" if company.blank?
    raise CallbackError, "Exigo integration not enabled" unless company.integration_setting&.exigo_enabled?

    ExigoClient.for_company(company)
  end

  def is_preferred_customer?(email)
    return false if email.blank?

    customer_id = cart_customer_id || get_customer_id_by_email(email)
    if customer_id.present?
      customer_type = get_customer_type_from_metafields(customer_id)
      return true if customer_type == PREFERRED_CUSTOMER_TYPE
    end

    has_exigo_autoship_by_email?(email)
  end

  def update_pcc_metafield(fluid_customer_id, customer_type)
    return if fluid_customer_id.blank? || customer_type.blank?

    fluid_client.metafields.ensure_definition(
      namespace: "custom",
      key: "customer_type",
      value_type: "json",
      description: "Customer type for pricing (preferred_customer, retail, null)",
      owner_resource: "Customer"
    )

    json_value = { "customer_type" => customer_type.to_s }

    fluid_client.metafields.update(
      resource_type: "customer",
      resource_id: fluid_customer_id.to_i,
      namespace: "custom",
      key: "customer_type",
      value: json_value,
      value_type: "json",
      description: "Customer type for pricing (preferred_customer, retail, null)"
    )
  rescue FluidClient::ResourceNotFoundError
    fluid_client.metafields.create(
      resource_type: "customer",
      resource_id: fluid_customer_id.to_i,
      namespace: "custom",
      key: "customer_type",
      value: json_value,
      value_type: "json",
      description: "Customer type for pricing (preferred_customer, retail, null)"
    )
  rescue StandardError => e
    Rails.logger.error "Failed to update PCC metafield for customer #{fluid_customer_id}: #{e.message}"
  end

  def success_with_message(msg)
    { success: true, message: msg }
  end

  def log_cart_pricing_event(event_type:, preferred_applied:, additional_data: {})
    company = find_company
    return if company.blank?

    CartPricingEvent.create!(
      company: company,
      cart_id: cart&.dig("id"),
      email: cart&.dig("email"),
      event_type: event_type,
      preferred_pricing_applied: preferred_applied,
      items_count: cart_items.count,
      cart_total: calculate_cart_total,
      metadata: additional_data
    )
  rescue StandardError => e
    Rails.logger.error "[CartPricingEvent] Failed to log event: #{e.message}"
  end

  def calculate_cart_total
    cart_items.sum { |item| (item["price"].to_f || 0) * (item["quantity"].to_i || 1) }
  rescue StandardError
    0.0
  end
end
