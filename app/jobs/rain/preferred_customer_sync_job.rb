module Rain
  class PreferredCustomerSyncJob < ApplicationJob
    queue_as :default

    def perform
      companies_to_sync.each do |company|
        Rails.logger.info("[PreferredSyncJob] Processing company: #{company.name} (ID: #{company.id})")

        begin
          Rain::PreferredCustomerSyncService.new(company: company).call
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
        company.integration_setting&.exigo_enabled?
      end
    end
  end
end
