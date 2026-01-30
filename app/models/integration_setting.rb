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
