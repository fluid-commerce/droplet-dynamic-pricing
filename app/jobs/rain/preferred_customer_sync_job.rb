module Rain
  class PreferredCustomerSyncJob < ApplicationJob
    queue_as :default

    def perform
      check_if_company_is_rain(company.authentication_token)

      preferred_by_type = get_preferred_customer_type_id
      active_autoship_ids = get_customers_with_active_autoships
      exigo_preferred_ids = preferred_by_type.union(active_autoship_ids)

      fluid_client.customers.get(country_code: %w[US CA]) do |customer|
        if exigo_preferred_ids.include?(customer["id"])
          fluid_client.customers.append_metadata(customer["id"], { "customer_type" => "preferred" })
        end
      end
    end
  end

private

  def fluid_client
    @fluid_client ||= FluidClient.new(company.authentication_token)
  end

  def exigo_client
    @exigo_client ||= ExigoClient.new(company.integration_setting.exigo_connection_config)
  end

  def check_if_company_is_rain(authentication_token)
    Company.find_by(authentication_token: authentication_token)
    false unless company.present?
    true
  end

  def get_preferred_customer_type_id
    exigo_client.customers_by_type_id(company.integration_setting.preferred_customer_type_id)
  rescue ExigoClient::Error => e
    Rails.logger.error("[Rain::PreferredCustomerSyncJob] Error getting preferred customer type id: #{e.message}")
    nil
  end

  def get_customers_with_active_autoships
    exigo_client.customers_with_active_autoships
  rescue ExigoClient::Error => e
    Rails.logger.error("[Rain::PreferredCustomerSyncJob] Error getting customers with active autoships: #{e.message}")
    nil
  end
end
