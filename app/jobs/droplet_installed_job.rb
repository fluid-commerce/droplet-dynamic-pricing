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
      { event: "resumed", url: subscription_webhook_url(base_url, "subscription_resumed") },
      { event: "reactivated", url: subscription_webhook_url(base_url, "subscription_reactivated") },
      # No subscription.updated here: this droplet routes no /webhook path for
      # it, so registering it handed Fluid a URL that 404s on every dispatch.
      # DropletUninstalledJob still deletes any registration left from before.
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
    # Before reading the table, make sure it actually describes this droplet.
    # It used to be filled only by CallbackSyncService plus an operator
    # clicking activate, so a callback nobody clicked was never registered —
    # which is how cart_customer_attached and cart_customer_detached went
    # unregistered despite having routes and services all along.
    ::Callback.ensure_served!

    client = FluidClient.new(company.authentication_token)
    active_callbacks = ::Callback.active
    installed_callback_ids = []

    active_callbacks.each do |callback|
      begin
        # The model validates URLs on save, but rows activated before that
        # validation existed (or whose route was later deleted) are still in
        # the table — registering one hands Fluid a URL that 404s on every
        # dispatch, which is how TM3's verify_email_success registration
        # (Fluid reg 1410) came to exist. Refuse them here too.
        unless ::Callback.serves?(callback.url)
          Rails.logger.error(
            "[DropletInstalledJob] Refusing to register callback #{callback.name}: " \
            "#{callback.url.inspect} is not a callback URL this droplet serves"
          )
          next
        end

        # No country_codes, deliberately. Fluid reads that field as a delivery
        # filter, and it is inverted from how it sounds: a dispatch that carries
        # no country — every Callback::Client.notify caller, cart_country_changed
        # among them — matches ONLY registrations whose country_codes is empty
        # (Callback::Registration.scoped_to_country). Listing the countries this
        # droplet prices for would silently stop those callbacks from arriving,
        # with no error and nothing logged. Registering globally is what makes
        # cart_country_changed reach us at all.
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
      # Union, not replacement: Fluid re-delivers droplet.installed on retries
      # and reinstalls, and replacing the list orphaned the previous batch of
      # registration UUIDs beyond DropletUninstalledJob's reach.
      company.update(
        installed_callback_ids: (company.installed_callback_ids || []) | installed_callback_ids,
      )
    end
  end
end
