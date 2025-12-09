module Rain
  class PreferredCustomerSyncJob < ApplicationJob
    queue_as :default

    def perform
      return unless rain_company.present?
      return unless sync_enabled_for_rain?

      synchronize_preferred_customers
    end
  end

private

  def rain_company
    @rain_company ||= Company.find_by(fluid_company_id: ENV.fetch("RAIN_FLUID_COMPANY_ID", nil))
  end

  def fluid_client
    @fluid_client ||= FluidClient.new(rain_company.authentication_token)
  end

  def exigo_client
    @exigo_client ||= ExigoClient.new(exigo_credentials)
  end

  def synchronize_preferred_customers
    preferred_type_id = preferred_customer_type_id
    retail_type_id = retail_customer_type_id
    exigo_active_autoship_ids = exigo_client.customers_with_active_autoships

    fetch_fluid_customers.each do |customer|
      customer_id = customer["id"]
      next unless customer_id.present?

      has_exigo_autoship = exigo_active_autoship_ids.include?(customer_id) ||
        exigo_client.customer_has_active_autoship?(customer_id)

      if has_exigo_autoship
        ensure_fluid_preferred(customer_id)
        update_exigo_customer_type(customer_id, preferred_type_id)
        next
      end

      if fluid_client.customers.active_autoship?(customer_id)
        next
      end

      demote_customer(customer_id, retail_type_id)
    end
  end

  def ensure_fluid_preferred(customer_id)
    fluid_client.customers.append_metadata(customer_id, { "customer_type" => "preferred" })
  end

  def demote_customer(customer_id, retail_type_id)
    fluid_client.customers.append_metadata(customer_id, { "customer_type" => "retail" })
    update_exigo_customer_type(customer_id, retail_type_id)
  end

  def update_exigo_customer_type(customer_id, customer_type_id)
    return unless customer_type_id.present?

    exigo_client.update_customer_type(customer_id, customer_type_id)
  end

  def fetch_fluid_customers
    customers = []
    page = 1
    per_page = 100

    loop do
      response = fluid_client.customers.get(page: page, per_page: per_page, country_code: %w[US CA])
      page_customers = response["customers"] || []
      customers.concat(page_customers)
      break if page_customers.size < per_page

      page += 1
    end

    customers
  rescue FluidClient::Error => e
    Rails.logger.warn("Failed to fetch Fluid customers: #{e.message}")
    []
  end

  def exigo_credentials
    {
      "exigo_db_host" => rain_company.integration_settings.credentials.dig("exigo_db_host"),
      "db_exigo_username" => rain_company.integration_settings.credentials.dig("db_exigo_username"),
      "exigo_db_password" => rain_company.integration_settings.credentials.dig("exigo_db_password"),
      "exigo_db_name" => rain_company.integration_settings.credentials.dig("exigo_db_name"),
    }.compact
  end

  def preferred_customer_type_id
    rain_company.integration_settings.credentials.dig("preferred_customer_type_id")
  end

  def retail_customer_type_id
    rain_company.integration_settings.credentials.dig("retail_customer_type_id")
  end

  def sync_enabled_for_rain?
    rain_company.fluid_company_id.to_s == ENV.fetch("RAIN_FLUID_COMPANY_ID", nil).to_s
  end
end

