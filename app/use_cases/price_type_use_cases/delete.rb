module PriceTypeUseCases
  class Delete
    def self.call(price_type_id:, auth_token:)
      price_type = PriceType.find(price_type_id)

      client = FluidClient.new(auth_token)

      filter = { "customer_type" => price_type.name }
      response = client.customers.get(by_metadata: filter, per_page: 1)
      customers = response["customers"] || []

      return failure("Cannot delete price type: it is in use by one or more customers") if customers.any?

      price_type.destroy!
      success
    rescue ActiveRecord::RecordNotFound => e
      failure("Price type not found: #{e.message}")
    rescue FluidClient::Error => e
      failure("Failed to check customer usage: #{e.message}")
    rescue ActiveRecord::RecordNotDestroyed => e
      failure("Failed to delete price type: #{e.message}")
    end

  private

    def self.success(data = {})
      { success: true }.merge(data)
    end

    def self.failure(error_message)
      { success: false, error: error_message }
    end
  end
end
