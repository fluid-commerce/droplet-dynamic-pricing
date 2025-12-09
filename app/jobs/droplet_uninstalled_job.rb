class DropletUninstalledJob < WebhookEventJob
  queue_as :default

  def process_webhook
    validate_payload_keys("company")
    company = get_company

    if company.present?
      delete_installed_callbacks(company)
      delete_subscription_webhooks(company)

      company.update(uninstalled_at: Time.current)
    else
      Rails.logger.warn("[DropletUninstalledJob] Company not found for payload: #{get_payload.inspect}")
    end
  end

private

  def delete_subscription_webhooks(company)
    client = FluidClient.new(company.authentication_token)
    subscription_webhooks = fetch_subscription_webhooks(client)

    subscription_webhooks.each do |webhook|
      begin
        delete_subscription_webhook(client, webhook)
      rescue => e
        Rails.logger.error(
          "[DropletUninstalledJob] Failed to delete subscription.#{webhook["event"]} " \
          "webhook #{webhook["id"]}: #{e.message}"
        )
      end
    end
  rescue => e
    Rails.logger.error(
      "[DropletUninstalledJob] Failed to get webhooks for deletion: #{e.message}"
    )
  end

  def fetch_subscription_webhooks(client)
    response = client.webhooks.get
    webhooks = response["webhooks"] || []

    webhooks.select do |webhook|
      webhook["resource"] == "subscription" &&
        %w[started paused cancelled].include?(webhook["event"])
    end
  end

  def delete_subscription_webhook(client, webhook)
    client.webhooks.delete(webhook["id"])
    Rails.logger.info(
      "[DropletUninstalledJob] Successfully deleted subscription.#{webhook["event"]} " \
      "webhook: #{webhook["id"]}"
    )
  end

  def delete_installed_callbacks(company)
    return unless company.installed_callback_ids.present?

    client = FluidClient.new(company.authentication_token)

    company.installed_callback_ids.each do |callback_id|
      begin
        client.callback_registrations.delete(callback_id)
      rescue => e
        Rails.logger.error("[DropletUninstalledJob] Failed to delete callback #{callback_id}: #{e.message}")
      end
    end

    company.update(installed_callback_ids: [])
  end
end
