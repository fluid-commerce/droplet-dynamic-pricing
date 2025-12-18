# frozen_string_literal: true

module Rain
  class CustomerSyncPageJob < ApplicationJob
    queue_as :default

    retry_on FluidClient::TimeoutError, wait: 30.seconds, attempts: 3
    retry_on FluidClient::Error, wait: 1.minute, attempts: 3
    retry_on ExigoClient::Error, wait: 1.minute, attempts: 3
    retry_on Net::OpenTimeout, wait: 2.minutes, attempts: 3

    def perform(company_id:, customers:, exigo_active_autoship_ids:, preferred_type_id:, retail_type_id:)
      company = Company.find(company_id)

      CustomerSyncPageService.new(
        company: company,
        customers: customers,
        exigo_active_autoship_ids: exigo_active_autoship_ids,
        preferred_type_id: preferred_type_id,
        retail_type_id: retail_type_id
      ).call
    end
  end
end
