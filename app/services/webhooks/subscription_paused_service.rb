# frozen_string_literal: true

class Webhooks::SubscriptionPausedService < Webhooks::BaseService
  def self.call(webhook_params, company)
    new(webhook_params, company).call
  end

  def call
    customer_id_value = customer_id
    subscription_id_value = subscription_id

    if customer_id_value.blank?
      return { success: false, error: "Customer ID not found in webhook params" }
    end

    if should_remain_preferred?(customer_id_value, subscription_id_value)
      return { success: true, message: "Customer has other subscriptions or Exigo autoship, no action taken" }
    end

    set_customer_retail(customer_id_value)

    { success: true, message: "Subscription paused webhook processed successfully" }
  rescue StandardError => e
    Rails.logger.error "Error processing subscription_paused webhook: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    { success: false, error: e.message }
  end
end
