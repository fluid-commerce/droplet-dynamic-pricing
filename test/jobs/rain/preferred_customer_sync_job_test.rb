require "test_helper"

module Rain
  class PreferredCustomerSyncJobTest < ActiveJob::TestCase
    fixtures(:companies)

    def test_delegates_to_service
      company = companies(:acme)
      ENV["RAIN_FLUID_COMPANY_ID"] = company.fluid_company_id.to_s

      service_called = false
      service_company = nil

      # Mock the service to capture the call
      Rain::PreferredCustomerSyncService.stub(:new, ->(company:) {
        service_company = company
        mock_service = Object.new
      mock_service.define_singleton_method(:call) do
          service_called = true
          true
        end
        mock_service
      }) do
        perform_enqueued_jobs { PreferredCustomerSyncJob.perform_later }
      end

      assert service_called, "Service should have been called"
      assert_equal company, service_company, "Service should receive the correct company"
    end

    def test_skips_when_company_not_found
      ENV["RAIN_FLUID_COMPANY_ID"] = "999999999"

      service_called = false

      Rain::PreferredCustomerSyncService.stub(:new, ->(_) {
        service_called = true
        Object.new
      }) do
        perform_enqueued_jobs { PreferredCustomerSyncJob.perform_later }
      end

      refute service_called, "Service should not be called when company not found"
    end

    def test_skips_when_fluid_company_id_missing
      ENV.delete("RAIN_FLUID_COMPANY_ID")

      service_called = false

      Rain::PreferredCustomerSyncService.stub(:new, ->(_) {
        service_called = true
        Object.new
      }) do
        perform_enqueued_jobs { PreferredCustomerSyncJob.perform_later }
      end

      refute service_called, "Service should not be called when RAIN_FLUID_COMPANY_ID is missing"
    end
  end
end
