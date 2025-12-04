class DropletUninstalledJob < WebhookEventJob
  queue_as :default

  def process_webhook
    validate_payload_keys("company")
    company = get_company

    if company.present?
      deactivate_callbacks_from_routes
      delete_installed_callbacks(company)

      company.update(uninstalled_at: Time.current, active: false)
    else
      Rails.logger.warn("[DropletUninstalledJob] Company not found for payload: #{get_payload.inspect}")
    end
  end

private

  ROUTE_TO_DEFINITION_NAME = {
    "subscription_added" => "cart_subscription_added",
    "subscription_removed" => "cart_subscription_removed",
    "cart_item_added" => "cart_item_added",
    "verify_email_success" => "verify_email_success",
    "cart_email_on_create" => "cart_email_on_create",
  }.freeze

  def deactivate_callbacks_from_routes
    callback_routes = extract_callback_routes

    callback_routes.each do |route_name, _route_path|
      definition_name = translate_route_name(route_name)
      deactivate_callback(definition_name, route_name)
    end
  rescue StandardError => e
    Rails.logger.error "[DropletUninstalledJob] Error deactivating callbacks from routes: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    raise
  end

  def translate_route_name(route_name)
    route_name_str = route_name.to_s
    ROUTE_TO_DEFINITION_NAME[route_name_str] || route_name_str
  end

  def deactivate_callback(definition_name, route_name)
    callback = ::Callback.find_by(name: definition_name)
    if callback.present?
      callback.update(active: false)
      Rails.logger.info "[DropletUninstalledJob] Deactivated callback: #{definition_name} (route: #{route_name})"
    else
      Rails.logger.warn "[DropletUninstalledJob] Callback not found for deactivation: #{definition_name}"
    end
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

  def delete_installed_callbacks(company)
    return unless company.installed_callback_ids.present?

    client = FluidClient.new(company.authentication_token)

    company.installed_callback_ids.each do |callback_id|
      begin
        client.callback_registrations.delete(callback_id)
        Rails.logger.info "[DropletUninstalledJob] Successfully deleted callback registration: #{callback_id}"
      rescue FluidClient::Error => e
        Rails.logger.error(
          "[DropletUninstalledJob] Failed to delete callback #{callback_id}: #{e.message}"
        )
      rescue StandardError => e
        Rails.logger.error(
          "[DropletUninstalledJob] Unexpected error deleting callback #{callback_id}: #{e.message}"
        )
        next
      end
    end

    company.update(installed_callback_ids: [])
  end
end
