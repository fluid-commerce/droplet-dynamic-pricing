module Rain
  class PreferredCustomerSyncJob < ApplicationJob
    queue_as :default

    before_perform :set_rain_company

    def perform
      return unless rain_company

      Rain::PreferredCustomerSyncService.new(company: rain_company).call
    end

  private

    attr_reader :rain_company

    def set_rain_company
      fluid_company_id = ENV.fetch("RAIN_FLUID_COMPANY_ID", nil)
      return unless fluid_company_id

      company = Company.find_by(fluid_company_id: fluid_company_id)
      return unless company.present?

      @rain_company = company
    end
  end
end
