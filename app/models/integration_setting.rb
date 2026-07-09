# frozen_string_literal: true

class IntegrationSetting < ApplicationRecord
  belongs_to :company

  validates :company_id, presence: true
  def exigo_enabled?
    enabled && credentials.present? && exigo_credentials_valid?
  end

  def exigo_credentials
    {
      db_host: credentials.dig("exigo_db_host"),
      db_username: credentials.dig("exigo_db_username"),
      db_password: credentials.dig("exigo_db_password"),
      db_name: credentials.dig("exigo_db_name"),
      api_base_url: credentials.dig("api_base_url"),
      api_username: credentials.dig("api_username"),
      api_password: credentials.dig("api_password"),
    }
  end

  # When enabled, dynamic pricing yields (no-ops) on BP enrollment carts so the
  # yoli-promos droplet's wholesale pricing takes precedence (STU2-2377). Only
  # relevant for companies that also run yoli-promos (i.e. Yoli); off by default
  # so every other company keeps getting preferred-customer pricing on
  # enrollment carts.
  def yield_to_enrollment_wholesale?
    ActiveModel::Type::Boolean.new.cast(settings.dig("yield_to_enrollment_wholesale")) || false
  end

  # When enabled, dynamic pricing also adjusts each cart item's volumes (QV/CV)
  # to reflect the subscription price, proportionally to the discount (STU2-2526).
  # Off by default: the droplet is shared, and Yoli already manages its volumes
  # via the yoli-promos/yoli-rewards droplets, so only companies that opt in get
  # volume adjustments.
  def adjust_volumes_for_subscription?
    ActiveModel::Type::Boolean.new.cast(settings.dig("adjust_volumes_for_subscription")) || false
  end

  # Subscription CV/QV volume sources (see #subscription_volume_source).
  DEFAULT_SUBSCRIPTION_VOLUME_SOURCE = "price_ratio"
  PREFERRED_CUSTOMER_VOLUME_SOURCE = "preferred_customer"

  # Where subscription CV/QV come from when adjust_volumes_for_subscription? is
  # on. "price_ratio" (default) scales the variant's retail volumes by the
  # subscription discount — today's behavior for every company. "preferred_customer"
  # instead writes the catalog's preferred-customer volumes (pc_cv/pc_qv) directly,
  # with no ratio scaling (Oliabo, whose PRIMA retail cv/qv differ from the correct
  # subscription volumes). Defaults to "price_ratio" so existing companies are
  # unaffected.
  def subscription_volume_source
    settings.dig("subscription_volume_source") || DEFAULT_SUBSCRIPTION_VOLUME_SOURCE
  end

  def preferred_customer_type_id
    settings.dig("preferred_customer_type_id") || "2"
  end

  def retail_customer_type_id
    settings.dig("retail_customer_type_id") || "1"
  end

  def api_delay_seconds
    settings.dig("api_delay_seconds")&.to_f || 0.5
  end

  def snapshots_to_keep
    settings.dig("snapshots_to_keep")&.to_i || 5
  end

  def daily_warmup_limit
    settings.dig("daily_warmup_limit")&.to_i || 10_000
  end

private

  def exigo_credentials_valid?
    creds = exigo_credentials
    creds[:db_host].present? &&
      creds[:db_username].present? &&
      creds[:db_password].present? &&
      creds[:db_name].present? &&
      creds[:api_base_url].present? &&
      creds[:api_username].present? &&
      creds[:api_password].present?
  end
end
