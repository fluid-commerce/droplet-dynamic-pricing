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
    @webhook_params.dig("subscription", "customer", "id")
  end

  def subscription_id
    @webhook_params.dig("subscription", "id")
  end

  def customer_external_id_from_payload
    @webhook_params.dig("subscription", "customer", "external_id")
  end

  def update_customer_type(customer_id, customer_type)
    raise ArgumentError, "customer_type cannot be blank" if customer_type.blank?

    client = FluidClient.new(@company.authentication_token)
    client.metafields.ensure_definition(
      namespace: "custom",
      key: "customer_type",
      value_type: "json",
      description: "Customer type for pricing (preferred_customer, retail, null)",
      owner_resource: "Customer"
    )

    json_value = { "customer_type" => customer_type.to_s }

    client.metafields.update(
      resource_type: "customer",
      resource_id: customer_id.to_i,
      namespace: "custom",
      key: "customer_type",
      value: json_value,
      value_type: "json",
      description: "Customer type for pricing (preferred_customer, retail, null)"
    )
  rescue FluidClient::ResourceNotFoundError
    client.metafields.create(
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
    client = FluidClient.new(@company.authentication_token)
    response = client.subscriptions.get_by_customer(customer_id, status: "active")
    subscriptions = response["subscriptions"] || []

    if exclude_subscription_id.present?
      subscriptions = subscriptions.reject { |sub| sub["id"] == exclude_subscription_id.to_i }
    end

    subscriptions.any?
  rescue FluidClient::ResourceNotFoundError
    false
  rescue FluidClient::Error
    false
  end

  def customer_external_id(customer_id)
    external_id = customer_external_id_from_payload
    return external_id if external_id.present?

    client = FluidClient.new(@company.authentication_token)
    customer = client.customers.find(customer_id)
    customer["external_id"]
  rescue StandardError
    nil
  end

  def has_exigo_autoship?(external_id)
    return false if external_id.blank?

    exigo_client.customer_has_active_autoship?(external_id)
  rescue StandardError
    false
  end

  def update_customer_metadata(customer_id, customer_type)
    client = FluidClient.new(@company.authentication_token)
    client.customers.append_metadata(customer_id, { "customer_type" => customer_type })
  rescue StandardError
    # Silently fail - metadata is secondary
  end

  def update_exigo_customer_type(external_id, customer_type)
    return if external_id.blank?

    type_id = (customer_type == PREFERRED_CUSTOMER_TYPE ? preferred_type_id : retail_type_id).to_i
    current_type_id = exigo_client.get_customer_type(external_id)

    return if current_type_id == type_id

    exigo_client.update_customer_type(external_id, type_id)
  rescue StandardError
    # Silently fail - Exigo update is secondary
  end

  def exigo_client
    @exigo_client ||= ExigoClient.for_company(@company.name)
  end

  def preferred_type_id
    ENV.fetch("RAIN_PREFERRED_CUSTOMER_TYPE_ID", "2")
  end

  def retail_type_id
    ENV.fetch("RAIN_RETAIL_CUSTOMER_TYPE_ID", "1")
  end

  def set_customer_preferred(customer_id)
    external_id = customer_external_id(customer_id)

    update_customer_type(customer_id, PREFERRED_CUSTOMER_TYPE)
    update_customer_metadata(customer_id, PREFERRED_CUSTOMER_TYPE)
    update_exigo_customer_type(external_id, PREFERRED_CUSTOMER_TYPE)
  end

  def set_customer_retail(customer_id)
    external_id = customer_external_id(customer_id)

    update_customer_type(customer_id, RETAIL_CUSTOMER_TYPE)
    update_customer_metadata(customer_id, RETAIL_CUSTOMER_TYPE)
    update_exigo_customer_type(external_id, RETAIL_CUSTOMER_TYPE)
  end

  def should_remain_preferred?(customer_id, exclude_subscription_id = nil)
    return true if has_other_active_subscriptions?(customer_id, exclude_subscription_id)

    external_id = customer_external_id(customer_id)
    return true if has_exigo_autoship?(external_id)

    false
  end
end
