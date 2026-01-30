# frozen_string_literal: true

class PreferredCustomerSyncJob < ApplicationJob
  queue_as :default

  def perform
    companies_to_sync.each do |company|
      Rails.logger.info("[PreferredSyncJob] Processing company: #{company.name} (ID: #{company.id})")

      begin
        PreferredCustomerSyncService.new(company: company).call
        Rails.logger.info("[PreferredSyncJob] Successfully synced company: #{company.name}")
      rescue StandardError => e
        Rails.logger.error("[PreferredSyncJob] Failed to sync company #{company.name}: #{e.message}")
        Rails.logger.error(e.backtrace.join("\n"))
      end
    end
  end

private

  def companies_to_sync
    Company.active.includes(:integration_setting).select do |company|
      (company.integration_setting&.exigo_enabled?) || exigo_env_credentials_present?(company)
    end
  end

  def exigo_env_credentials_present?(company)
    prefix = company.name.to_s.upcase.gsub(/\W/, "_")
    required = %w[
      EXIGO_DB_HOST EXIGO_DB_NAME EXIGO_DB_USERNAME EXIGO_DB_PASSWORD
      EXIGO_API_BASE_URL EXIGO_API_USERNAME EXIGO_API_PASSWORD
    ]
    required.all? { |k| ENV["#{prefix}_#{k}"].present? }
  end
end
