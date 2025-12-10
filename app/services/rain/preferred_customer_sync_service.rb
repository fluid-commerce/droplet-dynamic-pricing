# frozen_string_literal: true

module Rain
  class PreferredCustomerSyncService
    FLUID_CUSTOMERS_PER_PAGE = 100
    FLUID_CUSTOMERS_INITIAL_PAGE = 1

    def initialize(company:)
      raise ArgumentError, "company must be a Company" unless company.is_a?(Company)

      @company = company
    end

    def synchronize
      Rails.logger.info("[PreferredSync] synchronize_preferred_customers start")

      preferred_type_id = preferred_customer_type_id
      retail_type_id = retail_customer_type_id

      begin
        exigo_active_autoship_ids = exigo_client.customers_with_active_autoships
        Rails.logger.info("[PreferredSync] exigo_active_autoships count=#{exigo_active_autoship_ids.size}")
      rescue ExigoClient::Error => e
        Rails.logger.error("[PreferredSync] Failed to fetch Exigo autoships: #{e.message}")
        Rails.logger.error("[PreferredSync] Aborting sync - cannot proceed without Exigo data")
        return false
      end

      kept = 0
      demoted = 0

      fetch_fluid_customers.each do |customer|
        customer_id = customer["id"]
        Rails.logger.info("[PreferredSync] processing customer_id=#{customer_id}")
        next unless customer_id.present?

        begin
          begin
            has_exigo_autoship =
              exigo_active_autoship_ids.include?(customer_id) ||
              exigo_client.customer_has_active_autoship?(customer_id)
          rescue ExigoClient::Error => e
            Rails.logger.error("[PreferredSync] Failed to check Exigo autoship for #{customer_id}:#{e.message}")
            Rails.logger.info("[PreferredSync] Skipping customer #{customer_id} due to Exigo error")
            next
          end

          Rails.logger.info("[PreferredSync] exigo_autoship=#{has_exigo_autoship}")

          if has_exigo_autoship
            ensure_fluid_preferred(customer_id)
            update_exigo_customer_type(customer_id, preferred_type_id)
            kept += 1
            next
          end

          begin
            fluid_autoship = fluid_client.customers.active_autoship?(customer_id)
            Rails.logger.info("[PreferredSync] fluid_autoship=#{fluid_autoship}")
          rescue FluidClient::Error => e
            Rails.logger.error("[PreferredSync] Failed to check Fluid autoship for #{customer_id}:#{e.message}")
            Rails.logger.info("[PreferredSync] Skipping customer #{customer_id} due to Fluid error")
            next
          end

          if fluid_autoship
            kept += 1
            next
          end

          demote_customer(customer_id, retail_type_id)
          demoted += 1

        rescue FluidClient::Error => e
          Rails.logger.error("[PreferredSync] Failed to process customer #{customer_id}: #{e.message}")
          Rails.logger.info("[PreferredSync] Skipping customer #{customer_id} due to Fluid error")
          next
        end
      end

      Rails.logger.info("[PreferredSync] summary kept=#{kept} demoted=#{demoted}")
      true
    end

  private

    def fluid_client
      @fluid_client ||= FluidClient.new(@company.authentication_token)
    end

    def exigo_client
      @exigo_client ||= ExigoClient.for_company(@company.name)
    end

    def ensure_fluid_preferred(customer_id)
      begin
        fluid_client.customers.append_metadata(
          customer_id,
          { "customer_type" => "preferred_customer" }
        )
        Rails.logger.info("[PreferredSync] Updated Fluid customer #{customer_id} to preferred_customer")
      rescue FluidClient::Error => e
        Rails.logger.error("[PreferredSync] Failed to update Fluid preferred status for #{customer_id}: #{e.message}")
        raise
      end
    end

    def demote_customer(customer_id, retail_type_id)
      Rails.logger.info(
        "[PreferredSync] demote_customer customer_id=#{customer_id} retail_type_id=#{retail_type_id}"
      )

      begin
        fluid_client.customers.append_metadata(
          customer_id,
          { "customer_type" => "retail" }
        )
        Rails.logger.info("[PreferredSync] Updated Fluid customer #{customer_id} to retail")
      rescue FluidClient::Error => e
        Rails.logger.error("[PreferredSync] Failed to update Fluid retail status for #{customer_id}: #{e.message}")
        raise
      end

      update_exigo_customer_type(customer_id, retail_type_id)
    end

    def update_exigo_customer_type(customer_id, customer_type_id)
      return unless customer_type_id.present?

      begin
        exigo_client.update_customer_type(customer_id, customer_type_id)
        Rails.logger.info("[PreferredSync] Updated Exigo customer type for #{customer_id} to #{customer_type_id}")
      rescue ExigoClient::Error => e
        Rails.logger.error("[PreferredSync] Failed to update Exigo customer type for #{customer_id}: #{e.message}")
      end
    end

    def fetch_fluid_customers
      Rails.logger.info("[PreferredSync] fetch_fluid_customers start")

      customers = []
      page = FLUID_CUSTOMERS_INITIAL_PAGE

      loop do
        response = fluid_client.customers.get(
          page: page,
          per_page: FLUID_CUSTOMERS_PER_PAGE,
          country_code: %w[US CA]
        )

        page_customers = response["customers"] || []
        customers.concat(page_customers)

        break if page_customers.size < FLUID_CUSTOMERS_PER_PAGE

        page += 1
      end

      customers
    rescue FluidClient::Error => e
      Rails.logger.warn("Failed to fetch Fluid customers: #{e.message}")
      []
    end


    def preferred_customer_type_id
      ENV.fetch("RAIN_PREFERRED_CUSTOMER_TYPE_ID", nil)
    end

    def retail_customer_type_id
      ENV.fetch("RAIN_RETAIL_CUSTOMER_TYPE_ID", nil)
    end
  end
end
