# frozen_string_literal: true

class Webhooks::BaseService
  PREFERRED_CUSTOMER_TYPE = "preferred_customer"
  RETAIL_CUSTOMER_TYPE = "retail"

  def initialize(webhook_params, company)
    @webhook_params = webhook_params
    @company = company
  end

protected

  def customer_id
    @webhook_params.dig("subscription", "customer", "id") ||
      @webhook_params.dig(:subscription, :customer, :id) ||
      @webhook_params.dig("payload", "subscription", "customer", "id") ||
      @webhook_params.dig(:payload, :subscription, :customer, :id) ||
      @webhook_params.dig("payload", "customer", "id") ||
      @webhook_params.dig(:payload, :customer, :id)
  end

  def subscription_id
    @webhook_params.dig("subscription", "id")
  end

  def customer_external_id_from_payload
    @webhook_params.dig("subscription", "customer", "external_id")
  end

  def update_customer_type(customer_id, customer_type)
    if customer_type.blank?
      Rails.logger.error "customer_type is blank, cannot update metafield"
      raise ArgumentError, "customer_type cannot be blank"
    end

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
      resource_id: customer_id.to_i,
      namespace: "custom",
      key: "customer_type",
      value: json_value,
      value_type: "json",
      description: "Customer type for pricing (preferred_customer, retail, null)"
    )
  rescue FluidClient::ResourceNotFoundError => e
    Rails.logger.warn "Metafield not found for customer #{customer_id}; attempting create (#{e.message})"

    fluid_client.metafields.create(
      resource_type: "customer",
      resource_id: customer_id.to_i,
      namespace: "custom",
      key: "customer_type",
      value: json_value,
      value_type: "json",
      description: "Customer type for pricing (preferred_customer, retail, null)"
    )
  end

  def has_other_active_subscriptions?(customer_id, exclude_subscription_id = nil)
    response = fluid_client.subscriptions.get_by_customer(customer_id, status: "active")
    subscriptions = response["subscriptions"] || []

    if exclude_subscription_id.present?
      subscriptions = subscriptions.reject { |sub| sub["id"] == exclude_subscription_id.to_i }
    end

    subscriptions.any?
  rescue FluidClient::ResourceNotFoundError, FluidClient::Error
    false
  end

  def customer_external_id(customer_id)
    external_id = customer_external_id_from_payload
    return external_id if external_id.present?

    customer = fluid_client.customers.find(customer_id)
    customer["external_id"]
  rescue StandardError
    nil
  end

  def has_exigo_autoship?(external_id)
    return false unless exigo_integration_enabled?
    return false if external_id.blank?

    exigo_client.customer_has_active_autoship?(external_id)
  rescue StandardError
    false
  end

  def update_customer_metadata(customer_id, customer_type)
    fluid_client.customers.append_metadata(customer_id, { "customer_type" => customer_type })
  rescue StandardError => e
    Rails.logger.error "Failed to update customer metadata for customer #{customer_id}: #{e.message}"
  end

  def update_exigo_customer_type(external_id, customer_type)
    return unless exigo_integration_enabled?
    return if external_id.blank?

    type_id = (customer_type == PREFERRED_CUSTOMER_TYPE ? preferred_type_id : retail_type_id).to_i
    current_type_id = exigo_client.get_customer_type(external_id)

    return if current_type_id == type_id

    # COMMENTED FOR LOCAL TESTING - Uncomment to enable Exigo updates
    # exigo_client.update_customer_type(external_id, type_id)
    Rails.logger.info "[EXIGO UPDATE DISABLED] Would update customer #{external_id} to type #{type_id}"
  rescue StandardError => e
    Rails.logger.error "Failed to update Exigo customer type for external ID #{external_id}: #{e.message}"
  end

  def fluid_client
    @fluid_client ||= FluidClient.new(@company.authentication_token)
  end

  def exigo_client
    @exigo_client ||= ExigoClient.for_company(@company)
  end

  def preferred_type_id
    @company.integration_setting&.preferred_customer_type_id || "2"
  end

  def retail_type_id
    @company.integration_setting&.retail_customer_type_id || "1"
  end

  def exigo_integration_enabled?
    @company&.integration_setting&.exigo_enabled? || false
  end

  def set_customer_preferred(customer_id)
    set_customer_type(customer_id, PREFERRED_CUSTOMER_TYPE)
  end

  def set_customer_retail(customer_id)
    set_customer_type(customer_id, RETAIL_CUSTOMER_TYPE)
  end

  def set_customer_type(customer_id, customer_type)
    external_id = customer_external_id(customer_id)
    previous_type = get_current_customer_type(customer_id)

    update_customer_type(customer_id, customer_type)
    update_customer_metadata(customer_id, customer_type)
    update_exigo_customer_type(external_id, customer_type)

    log_transaction(
      customer_id: customer_id,
      external_id: external_id,
      previous_type: previous_type,
      new_type: customer_type,
      source: "webhook"
    )
  end

  def get_current_customer_type(customer_id)
    customer = fluid_client.customers.find(customer_id)
    customer.dig("metadata", "customer_type")
  rescue StandardError
    nil
  end

  def log_transaction(customer_id:, external_id:, previous_type:, new_type:, source:)
    CustomerTypeTransaction.create!(
      company: @company,
      customer_id: customer_id,
      external_id: external_id,
      previous_type: previous_type,
      new_type: new_type,
      source: source,
      metadata: {
        webhook_params: @webhook_params&.slice("subscription", "event_name"),
      }
    )
  rescue StandardError => e
    Rails.logger.error "Failed to log customer type transaction: #{e.message}"
  end

  def should_remain_preferred?(customer_id, exclude_subscription_id = nil)
    return true if has_other_active_subscriptions?(customer_id, exclude_subscription_id)

    external_id = customer_external_id(customer_id)
    return true if has_exigo_autoship?(external_id)

    false
  end
end
