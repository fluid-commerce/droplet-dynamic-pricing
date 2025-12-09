module Rain
  class PreferredCustomerSyncJob < ApplicationJob
    queue_as :default
    before_perform :set_rain_company
    def perform
      synchronize_preferred_customers
    end


private

  attr_reader :fluid_company_id, :rain_company

  def set_rain_company
    fluid_company_id = ENV.fetch("RAIN_FLUID_COMPANY_ID", nil)
    return unless fluid_company_id.present?

    company = Company.find_by(fluid_company_id: fluid_company_id)
    return unless company.present?

    @rain_company = company
  end

  def fluid_client
    @fluid_client ||= FluidClient.new(rain_company.authentication_token)
  end

  def exigo_client
    @exigo_client ||= ExigoClient.new(exigo_credentials)
  end

  def synchronize_preferred_customers
    Rails.logger.info("[PreferredSync] synchronize_preferred_customers start")
    preferred_type_id = preferred_customer_type_id
    retail_type_id = retail_customer_type_id
    exigo_active_autoship_ids = exigo_client.customers_with_active_autoships
    Rails.logger.info("[PreferredSync] exigo_active_autoships count=#{exigo_active_autoship_ids.size}")

    kept = 0
    demoted = 0
    fetch_fluid_customers.each do |customer|
      customer_id = customer["id"]
      Rails.logger.info("[PreferredSync] processing customer_id=#{customer_id}")
      next unless customer_id.present?

      has_exigo_autoship = exigo_active_autoship_ids.include?(customer_id) ||
        exigo_client.customer_has_active_autoship?(customer_id)
      Rails.logger.info("[PreferredSync] exigo_autoship=#{has_exigo_autoship}")

      if has_exigo_autoship
        ensure_fluid_preferred(customer_id)
        update_exigo_customer_type(customer_id, preferred_type_id)
        kept += 1
        next
      end

      fluid_autoship = fluid_client.customers.active_autoship?(customer_id)
      Rails.logger.info("[PreferredSync] fluid_autoship=#{fluid_autoship}")
      if fluid_autoship
        kept += 1
        next
      end

      demote_customer(customer_id, retail_type_id)
      demoted += 1
    end
    Rails.logger.info("[PreferredSync] summary kept=#{kept} demoted=#{demoted}")
  end

  def ensure_fluid_preferred(customer_id)
    fluid_client.customers.append_metadata(customer_id, { "customer_type" => "preferred_customer" })
  end

  def demote_customer(customer_id, retail_type_id)
    Rails.logger.info("[PreferredSync] demote_customer customer_id=#{customer_id} retail_type_id=#{retail_type_id}")
    fluid_client.customers.append_metadata(customer_id, { "customer_type" => "retail" })
    # update_exigo_customer_type(customer_id, retail_type_id) # disabled for testing (no Exigo writes)
  end

  def update_exigo_customer_type(customer_id, customer_type_id)
    return unless customer_type_id.present?

    # exigo_client.update_customer_type(customer_id, customer_type_id)
  end

  def fetch_fluid_customers
    Rails.logger.info("[PreferredSync] fetch_fluid_customers start")
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
      "exigo_db_host" => ENV.fetch("RAIN_EXIGO_DB_HOST", nil),
      "db_exigo_username" => ENV.fetch("RAIN_EXIGO_DB_USERNAME", nil),
      "exigo_db_password" => ENV.fetch("RAIN_EXIGO_DB_PASSWORD", nil),
      "exigo_db_name" => ENV.fetch("RAIN_EXIGO_DB_NAME", nil),
    }.compact
  end

  def preferred_customer_type_id
    ENV.fetch("RAIN_PREFERRED_CUSTOMER_TYPE_ID", nil)
  end

  def retail_customer_type_id
    ENV.fetch("RAIN_RETAIL_CUSTOMER_TYPE_ID", nil)
  end
end
end
