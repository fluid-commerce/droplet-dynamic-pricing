# frozen_string_literal: true

module Rain
  class PreferredCustomerSyncService
    PREFERRED_CUSTOMER_TYPE = "preferred_customer"
    RETAIL_CUSTOMER_TYPE = "retail"

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
      Rails.logger.info("[PreferredSync] Starting delta sync")

      # Get current autoships from Exigo
      today_ids = fetch_exigo_autoships
      return false if today_ids.nil?

      # Get yesterday's snapshot
      yesterday_ids = fetch_yesterday_snapshot

      # Calculate deltas
      new_autoships = today_ids - yesterday_ids
      lost_autoships = yesterday_ids - today_ids

      Rails.logger.info("[PreferredSync] Today: #{today_ids.size}, Yesterday: #{yesterday_ids.size}")
      Rails.logger.info("[PreferredSync] New autoships: #{new_autoships.size}, Lost: #{lost_autoships.size}")

      # Process new autoships → mark preferred
      processed_new = process_new_autoships(new_autoships)

      # Process lost autoships → demote if no Fluid subscription
      processed_lost = process_lost_autoships(lost_autoships)

      # Save today's snapshot for tomorrow
      save_snapshot(today_ids)

      Rails.logger.info("[PreferredSync] Complete. New: #{processed_new}, Demoted: #{processed_lost}")
      true
    end

    def fetch_exigo_autoships
      autoship_ids = exigo_client.customers_with_active_autoships
      autoship_ids.map(&:to_s)
    rescue ExigoClient::Error => e
      Rails.logger.error("[PreferredSync] Failed to fetch Exigo autoships: #{e.message}")
      nil
    end

    def fetch_yesterday_snapshot
      snapshot = ExigoAutoshipSnapshot.latest_for_company(@company)
      return [] if snapshot.blank?

      Rails.logger.info("[PreferredSync] Found snapshot from #{snapshot.synced_at}")
      snapshot.external_ids.map(&:to_s)
    end

    def process_new_autoships(external_ids)
      return 0 if external_ids.empty?

      count = 0

      external_ids.each do |external_id|
        customer = find_fluid_customer_by_external_id(external_id)
        next if customer.blank?

        customer_id = customer["id"]
        current_type = customer.dig("metadata", "customer_type")

        if current_type == PREFERRED_CUSTOMER_TYPE
          Rails.logger.debug("[PreferredSync] Customer #{customer_id} already preferred, skipping")
          next
        end

        set_customer_preferred(customer_id, external_id)
        count += 1
      rescue StandardError => e
        Rails.logger.error("[PreferredSync] Error processing new autoship #{external_id}: #{e.message}")
      end

      count
    end

    def process_lost_autoships(external_ids)
      count = 0

      external_ids.each do |external_id|
        customer = find_fluid_customer_by_external_id(external_id)
        next if customer.blank?

        customer_id = customer["id"]

        # Check if has active subscription in Fluid
        if has_fluid_subscription?(customer_id)
          Rails.logger.info("[PreferredSync] Customer #{customer_id} has Fluid subscription, keeping preferred")
          next
        end

        set_customer_retail(customer_id, external_id)
        count += 1
      rescue StandardError => e
        Rails.logger.error("[PreferredSync] Error processing lost autoship #{external_id}: #{e.message}")
      end

      count
    end

    def find_fluid_customer_by_external_id(external_id)
      response = fluid_client.customers.get(search_query: external_id)
      customers = response["customers"] || []
      customers.find { |c| c["external_id"].to_s == external_id.to_s }
    rescue StandardError => e
      Rails.logger.error("[PreferredSync] Error finding customer #{external_id}: #{e.message}")
      nil
    end

    def has_fluid_subscription?(customer_id)
      response = fluid_client.subscriptions.get_by_customer(customer_id, status: "active")
      subscriptions = response["subscriptions"] || []
      subscriptions.any?
    rescue StandardError
      false
    end

    def set_customer_preferred(customer_id, external_id)
      Rails.logger.info("[PreferredSync] Setting customer #{customer_id} to preferred")

      update_fluid_customer_type(customer_id, PREFERRED_CUSTOMER_TYPE)
      update_exigo_customer_type(external_id, preferred_type_id)
    end

    def set_customer_retail(customer_id, external_id)
      Rails.logger.info("[PreferredSync] Setting customer #{customer_id} to retail")

      update_fluid_customer_type(customer_id, RETAIL_CUSTOMER_TYPE)
      update_exigo_customer_type(external_id, retail_type_id)
    end

    def update_fluid_customer_type(customer_id, customer_type)
      # Update metafield
      fluid_client.metafields.ensure_definition(
        namespace: "custom",
        key: "customer_type",
        value_type: "json",
        description: "Customer type for pricing",
        owner_resource: "Customer"
      )

      fluid_client.metafields.update(
        resource_type: "customer",
        resource_id: customer_id.to_i,
        namespace: "custom",
        key: "customer_type",
        value: { "customer_type" => customer_type },
        value_type: "json"
      )

      fluid_client.customers.append_metadata(customer_id, { "customer_type" => customer_type })
    end

    def update_exigo_customer_type(external_id, type_id)
      return if external_id.blank? || type_id.blank?

      current_type = exigo_client.get_customer_type(external_id)
      return if current_type == type_id.to_i

      exigo_client.update_customer_type(external_id, type_id)
    end

    def save_snapshot(external_ids)
      ExigoAutoshipSnapshot.create!(
        company: @company,
        external_ids: external_ids,
        synced_at: Time.current
      )
      Rails.logger.info("[PreferredSync] Saved snapshot with #{external_ids.size} IDs")
    end

    def preferred_type_id
      ENV.fetch("RAIN_PREFERRED_CUSTOMER_TYPE_ID", "2")
    end

    def retail_type_id
      ENV.fetch("RAIN_RETAIL_CUSTOMER_TYPE_ID", "1")
    end
  end
end
