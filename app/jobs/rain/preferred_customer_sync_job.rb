module Rain
  class PreferredCustomerSyncJob < ApplicationJob
    queue_as :default

    def perform
      Rails.logger.info("Starting preferred customer sync")
    end
  end
end
