# frozen_string_literal: true

module Rain
  class PreferredCustomerSyncService
    FLUID_CUSTOMERS_PER_PAGE = 1
    FLUID_CUSTOMERS_INITIAL_PAGE = 1

    DELAY_BY_PAGE = [
      { max_page: 10, delay: 0.5 },
      { max_page: 30, delay: 1.0 },
      { max_page: 50, delay: 1.5 },
    ].freeze

    def initialize(company:)
      raise ArgumentError, "company must be a Company" unless company.is_a?(Company)

      @company = company
    end

    def call
      synchronize
    end

  private

    def fluid_client
      @fluid_client ||= FluidClient.new(@company.authentication_token)
    end

    def exigo_client
      @exigo_client ||= ExigoClient.for_company(@company.name)
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

      pages_enqueued = 0

      each_fluid_customer_page do |page_customers, page_number|
        Rails.logger.info("[PreferredSync] Enqueuing page #{page_number} with #{page_customers.size} customers")

        Rain::CustomerSyncJob.perform_later(
          company_id: @company.id,
          customers: page_customers,
          exigo_active_autoship_ids: exigo_active_autoship_ids,
          preferred_type_id: preferred_type_id,
          retail_type_id: retail_type_id
        )

        pages_enqueued += 1
        Rails.logger.info("[PreferredSync] Page #{page_number} enqueued. Total pages: #{pages_enqueued}")
      end

      Rails.logger.info("[PreferredSync] Finished enqueuing #{pages_enqueued} page sync jobs")
      true
    end

    def each_fluid_customer_page
      Rails.logger.info("[PreferredSync] Starting paginated customer fetch")

      page = FLUID_CUSTOMERS_INITIAL_PAGE

      loop do
        Rails.logger.info("[PreferredSync] Fetching page #{page}")

        response = fluid_client.customers.get(
          page: page,
          per_page: FLUID_CUSTOMERS_PER_PAGE,
          country_code: %w[US CA]
        )

        page_customers = response["customers"] || []

        Rails.logger.info("[PreferredSync] Page #{page}: #{page_customers.size} customers")

        yield page_customers, page if page_customers.any?

        break if page_customers.size < FLUID_CUSTOMERS_PER_PAGE

        delay = delay_for(page)
        Rails.logger.info("[PreferredSync] Waiting #{delay}s before next page")
        sleep(delay)

        page += 1
      end

      Rails.logger.info("[PreferredSync] Finished fetching all pages")
    rescue FluidClient::Error => e
      Rails.logger.error("[PreferredSync] Failed to fetch Fluid customers: #{e.message}")
    end

    def preferred_customer_type_id
      ENV.fetch("RAIN_PREFERRED_CUSTOMER_TYPE_ID", nil)
    end

    def retail_customer_type_id
      ENV.fetch("RAIN_RETAIL_CUSTOMER_TYPE_ID", nil)
    end

    def delay_for(page)
      DELAY_BY_PAGE.find { |r| page <= r[:max_page] }&.fetch(:delay, 2.0) || 2.0
    end
  end
end
