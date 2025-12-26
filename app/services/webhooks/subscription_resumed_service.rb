# frozen_string_literal: true

class Webhooks::SubscriptionResumedService < Webhooks::BaseService
  def self.call(webhook_params, company)
    new(webhook_params, company).call
  end

  def call
    customer_id_value = customer_id

    if customer_id_value.blank?
      return { success: false, error: "Customer ID not found in webhook params" }
    end

    set_customer_preferred(customer_id_value)

    { success: true, message: "Subscription resumed webhook processed successfully" }
  rescue StandardError => e
    Rails.logger.error "Error processing subscription_resumed webhook: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    { success: false, error: e.message }
  end
end
