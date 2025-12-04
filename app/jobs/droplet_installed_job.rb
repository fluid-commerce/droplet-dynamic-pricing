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

    create_callbacks_from_routes
    register_active_callbacks(company)
  end

private

  ROUTE_TO_DEFINITION_NAME = {
    "subscription_added" => "cart_subscription_added",
    "subscription_removed" => "cart_subscription_removed",
    "cart_item_added" => "cart_item_added",
    "verify_email_success" => "verify_email_success",
    "cart_email_on_create" => "cart_email_on_create",
  }.freeze

  def create_callbacks_from_routes
    callback_routes = extract_callback_routes
    base_url = Setting.host_server.base_url

    callback_routes.each do |route_name, route_path|
      route_name_str = route_name.to_s
      definition_name = ROUTE_TO_DEFINITION_NAME[route_name_str] || route_name_str
      callback_url = "#{base_url}#{route_path}"

      callback = ::Callback.find_or_initialize_by(name: definition_name)
      callback.assign_attributes(
        description: "Callback for #{route_name_str.humanize}",
        url: callback_url,
        timeout_in_seconds: 20,
        active: true
      )

      if callback.save
        Rails.logger.info "[DropletInstalledJob] Created/updated callback: #{definition_name}
                                            (route: #{route_name_str}) with URL: #{callback_url}"
      else
        Rails.logger.error "[DropletInstalledJob] Failed to create callback #{definition_name}:
                                                    #{callback.errors.full_messages.join(', ')}"
      end
    end
  rescue StandardError => e
    Rails.logger.error "[DropletInstalledJob] Error creating callbacks from routes: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
  end

  def extract_callback_routes
    Rails.application.routes.routes.select do |route|
      route.path.spec.to_s.start_with?("/callbacks/") && route.verb == "POST"
    end.map do |route|
      route_name = route.path.spec.to_s.gsub("/callbacks/", "").gsub("(.:format)", "").to_sym
      route_path = route.path.spec.to_s.gsub("(.:format)", "")
      [ route_name, route_path ]
    end.uniq
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
          Rails.logger.info(
            "[DropletInstalledJob] Successfully registered callback #{callback.name} with UUID: #{response["callback_registration"]["uuid"]}"
          )
        else
          Rails.logger.warn(
            "[DropletInstalledJob] Callback registered but no UUID returned for: #{callback.name}"
          )
        end
      rescue => e
        Rails.logger.error(
          "[DropletInstalledJob] Failed to register callback #{callback.name}: #{e.message}"
        )
      end
    end

    if installed_callback_ids.any?
      company.update(installed_callback_ids: installed_callback_ids)
    end
  end
end
