class Webhooks::SubscriptionCancelledService < Webhooks::BaseService
  def self.call(webhook_params, company)
    new(webhook_params, company).call
  end

  def call
    customer_id_value = customer_id
    if customer_id_value.blank?
      return { success: false, error: "Customer ID not found in webhook params" }
    end

    subscription_id_value = subscription_id

    if has_other_active_subscriptions?(customer_id_value, subscription_id_value)
      return { success: true, message: "Customer has other active subscriptions, no action taken" }
    end

    update_customer_type(customer_id_value, "retail")

    { success: true, message: "Subscription cancelled webhook processed successfully" }
  rescue StandardError => e
    Rails.logger.error "Error processing subscription_cancelled webhook: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    { success: false, error: e.message }
  end
end
