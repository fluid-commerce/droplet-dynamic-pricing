# frozen_string_literal: true

class PreferredCustomerSyncService
  PREFERRED_CUSTOMER_TYPE = "preferred_customer"
  RETAIL_CUSTOMER_TYPE = "retail"

  def initialize(company:)
    raise ArgumentError, "company must be a Company" unless company.is_a?(Company)
    @company = company
    @integration = company.integration_setting

    unless exigo_available?
      raise ArgumentError, "Exigo integration not enabled for #{company.name}"
    end
  end

  def call
    prepare_sync
    synchronize
  end

private

  def fluid_client
    @fluid_client ||= FluidClient.new(@company.authentication_token)
  end

  def exigo_client
    @exigo_client ||= ExigoClient.for_company(@company)
  end

  def prepare_sync
    fluid_client.metafields.ensure_definition(
      namespace: "custom",
      key: "customer_type",
      value_type: "json",
      description: "Customer type for pricing",
      owner_resource: "Customer"
    )
  end

  def synchronize
    Rails.logger.info("[PreferredSync] Starting sync")
    today_ids = fetch_exigo_autoships
    return false if today_ids.nil?
    yesterday_ids = fetch_yesterday_snapshot
    if warmup_needed?(today_ids, yesterday_ids)
      return run_warmup_sync(today_ids, yesterday_ids)
    end
    run_delta_sync(today_ids, yesterday_ids)
  end

  def warmup_needed?(today_ids, yesterday_ids)
    return true if yesterday_ids.empty?

    new_ids_count = (today_ids - yesterday_ids).size
    new_ids_count > daily_warmup_limit
  end

  def run_warmup_sync(today_ids, yesterday_ids)
    new_ids = today_ids - yesterday_ids

    Rails.logger.info("[PreferredSync] WARMUP MODE - Total new: #{new_ids.size}, Limit: #{daily_warmup_limit}")

    ids_to_process = new_ids.first(daily_warmup_limit)
    ids_remaining = new_ids.size - ids_to_process.size

    Rails.logger.info("[PreferredSync] Processing #{ids_to_process.size} today, #{ids_remaining} remaining")

    processed_count = process_new_autoships(ids_to_process)

    updated_snapshot_ids = yesterday_ids + ids_to_process
    save_snapshot(updated_snapshot_ids)

    snapshot_size = updated_snapshot_ids.size
    Rails.logger.info("[PreferredSync] Warmup complete. Processed: #{processed_count}, Snapshot: #{snapshot_size}")
    days_remaining = (ids_remaining.to_f / daily_warmup_limit).ceil
    Rails.logger.info("[PreferredSync] Days remaining: ~#{days_remaining}") if ids_remaining > 0

    true
  end

  def run_delta_sync(today_ids, yesterday_ids)
    new_autoships = today_ids - yesterday_ids
    lost_autoships = yesterday_ids - today_ids

    Rails.logger.info("[PreferredSync] DELTA MODE - Today: #{today_ids.size}, Yesterday: #{yesterday_ids.size}")
    Rails.logger.info("[PreferredSync] New autoships: #{new_autoships.size}, Lost: #{lost_autoships.size}")

    processed_new = process_new_autoships(new_autoships)

    processed_lost = process_lost_autoships(lost_autoships)

    save_snapshot(today_ids)

    Rails.logger.info("[PreferredSync] Delta sync complete. New: #{processed_new}, Demoted: #{processed_lost}")
    true
  end

  def fetch_exigo_autoships
    autoship_ids = exigo_client.customers_with_active_autoships
    return nil if autoship_ids.nil?

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
      sleep(api_delay_seconds)
    rescue StandardError => e
      Rails.logger.error("[PreferredSync] Error processing new autoship #{external_id}: #{e.message}")
    end

    count
  end

  def process_lost_autoships(external_ids)
    return 0 if external_ids.empty?

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
      sleep(api_delay_seconds)
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

    previous_type = get_current_customer_type(customer_id)
    update_fluid_customer_type(customer_id, PREFERRED_CUSTOMER_TYPE)
    update_exigo_customer_type(external_id, preferred_type_id)

    log_transaction(
      customer_id: customer_id,
      external_id: external_id,
      previous_type: previous_type,
      new_type: PREFERRED_CUSTOMER_TYPE,
      source: "sync_job"
    )
  end

  def set_customer_retail(customer_id, external_id)
    Rails.logger.info("[PreferredSync] Setting customer #{customer_id} to retail")

    previous_type = get_current_customer_type(customer_id)
    update_fluid_customer_type(customer_id, RETAIL_CUSTOMER_TYPE)
    update_exigo_customer_type(external_id, retail_type_id)

    log_transaction(
      customer_id: customer_id,
      external_id: external_id,
      previous_type: previous_type,
      new_type: RETAIL_CUSTOMER_TYPE,
      source: "sync_job"
    )
  end

  def update_fluid_customer_type(customer_id, customer_type)
    json_value = { "customer_type" => customer_type }

    begin
      fluid_client.metafields.update(
        resource_type: "customer",
        resource_id: customer_id.to_i,
        namespace: "custom",
        key: "customer_type",
        value: json_value,
        value_type: "json"
      )
    rescue FluidClient::ResourceNotFoundError
      fluid_client.metafields.create(
        resource_type: "customer",
        resource_id: customer_id.to_i,
        namespace: "custom",
        key: "customer_type",
        value: json_value,
        value_type: "json"
      )
    end

    fluid_client.customers.append_metadata(customer_id, json_value)
  rescue FluidClient::ResourceNotFoundError => e
    Rails.logger.warn("[PreferredSync] Customer #{customer_id} not found in Fluid: #{e.message}")
  end

  def update_exigo_customer_type(external_id, type_id)
    return if external_id.blank? || type_id.blank?

    current_type = exigo_client.get_customer_type(external_id)
    return if current_type == type_id.to_i

    # COMMENTED FOR LOCAL TESTING - Uncomment to enable Exigo updates
    # exigo_client.update_customer_type(external_id, type_id)
    Rails.logger.info("[EXIGO UPDATE DISABLED] Would update customer #{external_id} to type #{type_id}")
  end

  def save_snapshot(external_ids)
    ExigoAutoshipSnapshot.create!(
      company: @company,
      external_ids: external_ids,
      synced_at: Time.current
    )
    Rails.logger.info("[PreferredSync] Saved snapshot with #{external_ids.size} IDs")

    cleanup_old_snapshots
  end

  def cleanup_old_snapshots
    ids_to_keep = ExigoAutoshipSnapshot
      .where(company: @company)
      .order(synced_at: :desc)
      .limit(snapshots_to_keep)
      .pluck(:id)

    ExigoAutoshipSnapshot
      .where(company: @company)
      .where.not(id: ids_to_keep)
      .delete_all
  end

  def exigo_available?
    (@integration&.exigo_enabled?) || exigo_env_credentials_present?
  end

  def exigo_env_credentials_present?
    prefix = @company.name.to_s.upcase.gsub(/\W/, "_")
    required = %w[
      EXIGO_DB_HOST EXIGO_DB_NAME EXIGO_DB_USERNAME EXIGO_DB_PASSWORD
      EXIGO_API_BASE_URL EXIGO_API_USERNAME EXIGO_API_PASSWORD
    ]
    required.all? { |k| ENV["#{prefix}_#{k}"].present? }
  end

  def preferred_type_id
    @integration&.preferred_customer_type_id || 2
  end

  def retail_type_id
    @integration&.retail_customer_type_id || 1
  end

  def api_delay_seconds
    @integration&.api_delay_seconds || 0.5
  end

  def snapshots_to_keep
    @integration&.snapshots_to_keep || 5
  end

  def daily_warmup_limit
    @integration&.daily_warmup_limit || 10_000
  end

  def get_current_customer_type(customer_id)
    customer = find_fluid_customer_by_id(customer_id)
    return nil if customer.blank?

    customer.dig("metadata", "customer_type")
  rescue StandardError
    nil
  end

  def find_fluid_customer_by_id(customer_id)
    fluid_client.customers.find(customer_id)
  rescue StandardError => e
    Rails.logger.error("[PreferredSync] Error finding customer #{customer_id}: #{e.message}")
    nil
  end

  def log_transaction(customer_id:, external_id:, previous_type:, new_type:, source:)
    CustomerTypeTransaction.create!(
      company: @company,
      customer_id: customer_id,
      external_id: external_id,
      previous_type: previous_type,
      new_type: new_type,
      source: source,
      metadata: {
        preferred_type_id: preferred_type_id,
        retail_type_id: retail_type_id,
      }
    )
  rescue StandardError => e
    Rails.logger.error("[PreferredSync] Failed to log transaction: #{e.message}")
  end
end
