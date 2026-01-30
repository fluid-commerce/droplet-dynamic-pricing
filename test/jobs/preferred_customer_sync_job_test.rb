require "test_helper"

class PreferredCustomerSyncJobTest < ActiveJob::TestCase
  fixtures(:companies)

  def test_processes_all_companies_with_exigo_enabled
    acme = companies(:acme)
    globex = companies(:globex)

    acme_integration = IntegrationSetting.create!(
      company: acme,
      enabled: true,
      credentials: {
        exigo_db_host: "db.example.com",
        exigo_db_username: "user",
        exigo_db_password: "pass",
        exigo_db_name: "exigo_db",
        api_base_url: "https://api.example.com",
        api_username: "api_user",
        api_password: "api_pass",
      },
      settings: {}
    )

    IntegrationSetting.create!(
      company: globex,
      enabled: false,
      credentials: {},
      settings: {}
    )

    processed_companies = []

    PreferredCustomerSyncService.stub(:new, ->(company:) {
      processed_companies << company
      mock_service = Object.new
      mock_service.define_singleton_method(:call) { true }
      mock_service
    }) do
      perform_enqueued_jobs { PreferredCustomerSyncJob.perform_later }
    end

    assert_equal 1, processed_companies.size, "Should process only companies with Exigo enabled"
    assert_includes processed_companies, acme, "Should process acme (Exigo enabled)"
    refute_includes processed_companies, globex, "Should not process globex (Exigo disabled)"
  end

  def test_processes_multiple_companies_with_exigo_enabled
    acme = companies(:acme)
    globex = companies(:globex)

    acme_integration = IntegrationSetting.create!(
      company: acme,
      enabled: true,
      credentials: {
        exigo_db_host: "db.example.com",
        exigo_db_username: "user",
        exigo_db_password: "pass",
        exigo_db_name: "exigo_db",
        api_base_url: "https://api.example.com",
        api_username: "api_user",
        api_password: "api_pass",
      },
      settings: {}
    )

    globex_integration = IntegrationSetting.create!(
      company: globex,
      enabled: true,
      credentials: {
        exigo_db_host: "db2.example.com",
        exigo_db_username: "user2",
        exigo_db_password: "pass2",
        exigo_db_name: "exigo_db2",
        api_base_url: "https://api2.example.com",
        api_username: "api_user2",
        api_password: "api_pass2",
      },
      settings: {}
    )

    processed_companies = []

    PreferredCustomerSyncService.stub(:new, ->(company:) {
      processed_companies << company
      mock_service = Object.new
      mock_service.define_singleton_method(:call) { true }
      mock_service
    }) do
      perform_enqueued_jobs { PreferredCustomerSyncJob.perform_later }
    end

    assert_equal 2, processed_companies.size, "Should process both companies with Exigo enabled"
    assert_includes processed_companies, acme, "Should process acme"
    assert_includes processed_companies, globex, "Should process globex"
  end

  def test_continues_on_error_for_one_company
    acme = companies(:acme)
    globex = companies(:globex)

    IntegrationSetting.create!(
      company: acme,
      enabled: true,
      credentials: {
        exigo_db_host: "db.example.com",
        exigo_db_username: "user",
        exigo_db_password: "pass",
        exigo_db_name: "exigo_db",
        api_base_url: "https://api.example.com",
        api_username: "api_user",
        api_password: "api_pass",
      },
      settings: {}
    )

    IntegrationSetting.create!(
      company: globex,
      enabled: true,
      credentials: {
        exigo_db_host: "db2.example.com",
        exigo_db_username: "user2",
        exigo_db_password: "pass2",
        exigo_db_name: "exigo_db2",
        api_base_url: "https://api2.example.com",
        api_username: "api_user2",
        api_password: "api_pass2",
      },
      settings: {}
    )

    processed_companies = []

    PreferredCustomerSyncService.stub(:new, ->(company:) {
      processed_companies << company
      mock_service = Object.new
      mock_service.define_singleton_method(:call) do
        raise StandardError, "Test error" if company == acme
        true
      end
      mock_service
    }) do
      perform_enqueued_jobs { PreferredCustomerSyncJob.perform_later }
    end

    assert_equal 2, processed_companies.size, "Should attempt to process both companies"
    assert_includes processed_companies, acme, "Should attempt acme (even if it fails)"
    assert_includes processed_companies, globex, "Should process globex successfully"
  end

  def test_processes_company_with_env_credentials
    acme = companies(:acme)

    # No integration_setting or disabled integration
    IntegrationSetting.create!(
      company: acme,
      enabled: false,
      credentials: {},
      settings: {}
    )

    # Set ENV credentials
    company_prefix = acme.name.to_s.upcase.gsub(/\W/, "_")
    ENV["#{company_prefix}_EXIGO_DB_HOST"] = "env.db.example.com"
    ENV["#{company_prefix}_EXIGO_DB_NAME"] = "env_exigo_db"
    ENV["#{company_prefix}_EXIGO_DB_USERNAME"] = "env_user"
    ENV["#{company_prefix}_EXIGO_DB_PASSWORD"] = "env_pass"
    ENV["#{company_prefix}_EXIGO_API_BASE_URL"] = "https://env.api.example.com"
    ENV["#{company_prefix}_EXIGO_API_USERNAME"] = "env_api_user"
    ENV["#{company_prefix}_EXIGO_API_PASSWORD"] = "env_api_pass"

    processed_companies = []

    PreferredCustomerSyncService.stub(:new, ->(company:) {
      processed_companies << company
      mock_service = Object.new
      mock_service.define_singleton_method(:call) { true }
      mock_service
    }) do
      perform_enqueued_jobs { PreferredCustomerSyncJob.perform_later }
    end

    assert_equal 1, processed_companies.size, "Should process company with ENV credentials"
    assert_includes processed_companies, acme, "Should process acme with ENV credentials"
  ensure
    # Clean up ENV
    ENV.delete("#{company_prefix}_EXIGO_DB_HOST")
    ENV.delete("#{company_prefix}_EXIGO_DB_NAME")
    ENV.delete("#{company_prefix}_EXIGO_DB_USERNAME")
    ENV.delete("#{company_prefix}_EXIGO_DB_PASSWORD")
    ENV.delete("#{company_prefix}_EXIGO_API_BASE_URL")
    ENV.delete("#{company_prefix}_EXIGO_API_USERNAME")
    ENV.delete("#{company_prefix}_EXIGO_API_PASSWORD")
  end
end
