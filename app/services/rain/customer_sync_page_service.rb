# frozen_string_literal: true

module Rain
  class CustomerSyncPageService
    CUSTOMER_TYPE_PREFERRED = "preferred_customer"
    CUSTOMER_TYPE_RETAIL = "retail"
    METAFIELD_NAMESPACE = "custom"
    METAFIELD_KEY = "customer_type"
    METAFIELD_DESCRIPTION = "Customer type for pricing (preferred_customer, retail, null)"

    def initialize(company:, customers:, exigo_active_autoship_ids:, preferred_type_id:, retail_type_id:)
      @company = company
      @customers = customers
      @exigo_active_autoship_ids = exigo_active_autoship_ids
      @preferred_type_id = preferred_type_id
      @retail_type_id = retail_type_id
    end

    def call
      Rails.logger.info("[CustomerSync] Processing batch of #{@customers.size} customers")

      processed = 0
      skipped = 0
      failed = 0

      @customers.each do |customer|
        if process_customer(customer)
          processed += 1
        else
          skipped += 1
        end
      rescue StandardError => e
        failed += 1
        Rails.logger.error("[CustomerSync] Failed to process customer #{customer['id']}: #{e.message}")
        Sentry.capture_exception(e) if defined?(Sentry)
      end

      Rails.logger.info("[CustomerSync] Batch complete: #{processed} processed, #{skipped} skipped, #{failed} failed")

      { success: failed.zero?, processed: processed, skipped: skipped, failed: failed, total: @customers.size }
    end

  private

    attr_reader :preferred_type_id, :retail_type_id

    def process_customer(customer)
      customer_id = customer["id"]
      external_id = customer["external_id"]

      return false if customer_id.blank? || external_id.blank?

      Rails.logger.info("[CustomerSync] Processing customer_id=#{customer_id} external_id=#{external_id}")

      has_exigo_autoship = @exigo_active_autoship_ids.include?(external_id)

      if has_exigo_autoship
        keep_as_preferred(customer_id, external_id, reason: "Exigo autoship")
      elsif fluid_autoship?(customer_id)
        keep_as_preferred(customer_id, external_id, reason: "Fluid autoship")
      else
        demote_to_retail(customer_id, external_id)
      end

      true
    end

    def keep_as_preferred(customer_id, external_id, reason:)
      Rails.logger.info("[CustomerSync] Keeping customer #{customer_id} as preferred (#{reason})")
      set_fluid_customer_type(customer_id, CUSTOMER_TYPE_PREFERRED)
      update_exigo_customer_type(external_id, preferred_type_id)
    end

    def demote_to_retail(customer_id, external_id)
      Rails.logger.info("[CustomerSync] Demoting customer #{customer_id} to retail")
      set_fluid_customer_type(customer_id, CUSTOMER_TYPE_RETAIL)
      update_exigo_customer_type(external_id, retail_type_id)
    end

    def fluid_autoship?(customer_id)
      fluid_client.customers.active_autoship?(customer_id)
    end

    def set_fluid_customer_type(customer_id, customer_type)
      fluid_client.metafields.ensure_definition(
        namespace: METAFIELD_NAMESPACE,
        key: METAFIELD_KEY,
        value_type: "json",
        description: METAFIELD_DESCRIPTION,
        owner_resource: "Customer"
      )

      json_value = { METAFIELD_KEY => customer_type.to_s }

      fluid_client.metafields.update(
        resource_type: "customer",
        resource_id: customer_id.to_i,
        namespace: METAFIELD_NAMESPACE,
        key: METAFIELD_KEY,
        value: json_value,
        value_type: "json",
        description: METAFIELD_DESCRIPTION
      )
    rescue FluidClient::ResourceNotFoundError
      Rails.logger.warn("[CustomerSync] Metafield not found for customer #{customer_id}, creating")
      fluid_client.metafields.create(
        resource_type: "customer",
        resource_id: customer_id.to_i,
        namespace: METAFIELD_NAMESPACE,
        key: METAFIELD_KEY,
        value: json_value,
        value_type: "json",
        description: METAFIELD_DESCRIPTION
      )
    end

    def update_exigo_customer_type(external_id, customer_type_id)
      return if customer_type_id.blank?

      exigo_client.update_customer_type(external_id, customer_type_id)
      Rails.logger.info("[CustomerSync] Updated Exigo customer #{external_id} to type #{customer_type_id}")
    end

    def fluid_client
      @fluid_client ||= FluidClient.new(@company.authentication_token)
    end

    def exigo_client
      @exigo_client ||= ExigoClient.for_company(@company.name)
    end
  end
end
