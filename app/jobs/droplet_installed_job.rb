class DropletInstalledJob < WebhookEventJob
  # payload - Hash received from the webhook controller.
  # Expected structure (example):
  # {
  #   "company" => {
  #     "fluid_shop" => "example.myshopify.com",
  #     "name" => "Example Shop",
  #     "fluid_company_id" => 123,
  #     "company_droplet_uuid" => "uuid",
  #     "authentication_token" => "token",
  #     "webhook_verification_token" => "verify",
  #   }
  # }
  def process_webhook
    # Validate required keys in payload
    validate_payload_keys("company")
    company_attributes = get_payload.fetch("company", {})

    company = Company.find_by(fluid_shop: company_attributes["fluid_shop"]) || Company.new

    company.assign_attributes(company_attributes.slice(
      "fluid_shop",
      "name",
      "fluid_company_id",
      "authentication_token",
      "webhook_verification_token",
      "droplet_installation_uuid"
    ))
    company.company_droplet_uuid = company_attributes.fetch("droplet_uuid")
    company.active = true

    unless company.save
      Rails.logger.error(
        "[DropletInstalledJob] Failed to create company: #{company.errors.full_messages.join(', ')}"
      )
      return
    end

    register_active_callbacks(company)
    register_subscription_webhooks(company)
  rescue StandardError => e
    Rails.logger.error(
      "[DropletInstalledJob] Error registering callbacks or webhooks: #{e.message}"
    )
    Rails.logger.error e.backtrace.join("\n")
    raise
  end

private

  def register_subscription_webhooks(company)
    client = FluidClient.new(company.authentication_token)
    webhook_events = build_subscription_webhook_events(company)

    webhook_events.each do |webhook_config|
      begin
        register_subscription_webhook(client, webhook_config, company)
      rescue => e
        Rails.logger.error(
          "[DropletInstalledJob] Failed to register subscription.#{webhook_config[:event]} webhook: #{e.message}"
        )
      end
    end
  end

  def build_subscription_webhook_events(company)
    base_url = Setting.host_server.base_url
    [
      { event: "started", url: subscription_webhook_url(base_url, "subscription_started") },
      { event: "paused", url: subscription_webhook_url(base_url, "subscription_paused") },
      { event: "cancelled", url: subscription_webhook_url(base_url, "subscription_cancelled") },
    ]
  end

  def subscription_webhook_url(base_url, event_name)
    "#{base_url}/webhook/#{event_name}"
  end

  def register_subscription_webhook(client, webhook_config, company)
    webhook_attributes = build_webhook_attributes(webhook_config, company)
    response = client.webhooks.create(webhook_attributes)

    if response && response["webhook"] && response["webhook"]["id"]
      Rails.logger.info(
        "[DropletInstalledJob] Successfully registered subscription.#{webhook_config[:event]} " \
        "webhook: #{response["webhook"]["id"]}"
      )
    else
      Rails.logger.warn(
        "[DropletInstalledJob] Webhook registered but no ID returned for: subscription.#{webhook_config[:event]}"
      )
    end
  end

  def build_webhook_attributes(webhook_config, company)
    auth_token = company.webhook_verification_token || Setting.fluid_webhook.auth_token

    {
      resource: "subscription",
      event: webhook_config[:event],
      url: webhook_config[:url],
      active: true,
      auth_token: auth_token,
      http_method: "post",
    }
  end

  def register_active_callbacks(company)
    client = FluidClient.new(company.authentication_token)
    active_callbacks = ::Callback.active
    installed_callback_ids = []

    active_callbacks.each do |callback|
      begin
        callback_attributes = {
          definition_name: callback.name,
          url: callback.url,
          timeout_in_seconds: callback.timeout_in_seconds,
          active: true,
        }

        response = client.callback_registrations.create(callback_attributes)
        if response && response["callback_registration"]["uuid"]
          installed_callback_ids << response["callback_registration"]["uuid"]
        else
          Rails.logger.warn(
            "[DropletInstalledJob] Callback registered but no UUID returned for: #{callback.name}"
          )
        end
      rescue FluidClient::Error => e
        Rails.logger.error(
          "[DropletInstalledJob] Failed to register callback #{callback.name}: #{e.message}"
        )
      rescue StandardError => e
        Rails.logger.error(
          "[DropletInstalledJob] Unexpected error registering callback #{callback.name}: #{e.message}"
        )
        next
      end
    end

    if installed_callback_ids.any?
      company.update(installed_callback_ids: installed_callback_ids)
    end
  end
end
