class Webhooks::BaseService
  def initialize(webhook_params, company)
    @webhook_params = webhook_params
    @company = company
  end

protected

  def customer_id
    @webhook_params.dig("subscription", "customer", "id") ||
      @webhook_params.dig(:subscription, :customer, :id) ||
      @webhook_params.dig("payload", "customer", "id") ||
      @webhook_params.dig(:payload, :customer, :id)
  end

  def subscription_id
    @webhook_params.dig("subscription", "id")
  end

  def update_customer_type(customer_id, customer_type)
    if customer_type.blank?
      Rails.logger.error "customer_type is blank, cannot update metafield"
      raise ArgumentError, "customer_type cannot be blank"
    end

    json_value = { "customer_type" => customer_type.to_s }

    client = FluidClient.new(@company.authentication_token)
    client.metafields.update(
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
  rescue FluidClient::ResourceNotFoundError => e
    false
  rescue FluidClient::Error => e
    Rails.logger.error "Error checking active subscriptions for customer #{customer_id}: #{e.message}"
    Rails.logger.error "Assuming no other active subscriptions to be safe"
    false
  end
end
