# frozen_string_literal: true

module Rain
  class CustomerSyncPageJob < ApplicationJob
    queue_as :default

    retry_on FluidClient::TimeoutError, wait: 30.seconds, attempts: 3
    retry_on FluidClient::Error, wait: 1.minute, attempts: 3
    retry_on ExigoClient::Error, wait: 1.minute, attempts: 3
    retry_on Net::OpenTimeout, wait: 2.minutes, attempts: 3

    def perform(company_id:, customers:, exigo_active_autoship_ids:, preferred_type_id:, retail_type_id:)
      @company = Company.find(company_id)
      @exigo_active_autoship_ids = exigo_active_autoship_ids
      @preferred_type_id = preferred_type_id
      @retail_type_id = retail_type_id

      Rails.logger.info("[CustomerSync] Processing batch of #{customers.size} customers")

      customers.each do |customer|
        process_customer(customer)
      rescue StandardError => e
        Rails.logger.error("[CustomerSync] Failed to process customer #{customer['id']}: #{e.message}")
        Sentry.capture_exception(e) if defined?(Sentry)
      end

      Rails.logger.info("[CustomerSync] Batch complete")
    end

  private

    def process_customer(customer)
      customer_id = customer["id"]
      external_id = customer["external_id"]

      return if customer_id.blank? || external_id.blank?

      Rails.logger.info("[CustomerSync] Processing customer_id=#{customer_id} external_id=#{external_id}")

      has_exigo_autoship = @exigo_active_autoship_ids.include?(external_id)

      if has_exigo_autoship
        keep_as_preferred(customer_id, external_id)
      elsif fluid_autoship?(customer_id)
        Rails.logger.info("[CustomerSync] Customer #{customer_id} has Fluid autoship, keeping")
      else
        demote_to_retail(customer_id, external_id)
      end
    end

    def keep_as_preferred(customer_id, external_id)
      Rails.logger.info("[CustomerSync] Keeping customer #{customer_id} as preferred")
      set_fluid_customer_type(customer_id, "preferred_customer")
      update_exigo_customer_type(external_id, @preferred_type_id)
    end

    def demote_to_retail(customer_id, external_id)
      Rails.logger.info("[CustomerSync] Demoting customer #{customer_id} to retail")
      set_fluid_customer_type(customer_id, "retail")
      update_exigo_customer_type(external_id, @retail_type_id)
    end

    def fluid_autoship?(customer_id)
      fluid_client.customers.active_autoship?(customer_id)
    end

    def set_fluid_customer_type(customer_id, customer_type)
      fluid_client.metafields.ensure_definition(
        namespace: "custom",
        key: "customer_type",
        value_type: "json",
        description: "Customer type for pricing (preferred_customer, retail, null)",
        owner_resource: "Customer"
      )

      json_value = { "customer_type" => customer_type.to_s }

      fluid_client.metafields.update(
        resource_type: "customer",
        resource_id: customer_id.to_i,
        namespace: "custom",
        key: "customer_type",
        value: json_value,
        value_type: "json",
        description: "Customer type for pricing (preferred_customer, retail, null)"
      )
    rescue FluidClient::ResourceNotFoundError
      Rails.logger.warn("[CustomerSync] Metafield not found for customer #{customer_id}, creating")
      fluid_client.metafields.create(
        resource_type: "customer",
        resource_id: customer_id.to_i,
        namespace: "custom",
        key: "customer_type",
        value: json_value,
        value_type: "json",
        description: "Customer type for pricing (preferred_customer, retail, null)"
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
