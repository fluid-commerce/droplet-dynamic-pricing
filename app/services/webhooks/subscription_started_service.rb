class Webhooks::SubscriptionStartedService < Webhooks::BaseService
  def self.call(webhook_params, company)
    new(webhook_params, company).call
  end

  def call
    customer_id_value = customer_id
    if customer_id_value.blank?
      return { success: false, error: "Customer ID not found in webhook params" }
    end

    update_customer_type(customer_id_value, "preferred_customer")

    { success: true, message: "Subscription started webhook processed successfully" }
  rescue StandardError => e
    Rails.logger.error "Error processing subscription_started webhook: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    { success: false, error: e.message }
  end
end
