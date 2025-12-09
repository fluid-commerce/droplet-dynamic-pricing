require "test_helper"

describe DropletInstalledJob do
  before do
    Tasks::Settings.create_defaults
    Setting.host_server.update(values: { base_url: "https://test.example.com" }) if Setting.host_server.present?
  end

  describe "#perform" do
    it "creates a company from payload when company doesn't exist" do
      company_data = {
        "fluid_shop" => "unique-test-shop-123",
        "name" => "Test Shop",
        "fluid_company_id" => 12345,
        "droplet_uuid" => "test-uuid-123",
        "authentication_token" => "unique-test-auth-token",
        "webhook_verification_token" => "test-verify-token",
        "droplet_installation_uuid" => "test-installation-uuid-123",
      }

      payload = { "company" => company_data }

      _(-> { DropletInstalledJob.perform_now(payload) }).must_change "Company.count", +1

      # Find the created company
      company = Company.last

      # Verify company attributes
      _(company.fluid_shop).must_equal "unique-test-shop-123"
      _(company.name).must_equal "Test Shop"
      _(company.fluid_company_id).must_equal 12345
      _(company.company_droplet_uuid).must_equal "test-uuid-123"
      _(company.authentication_token).must_equal "unique-test-auth-token"
      _(company.webhook_verification_token).must_equal "test-verify-token"
      _(company.droplet_installation_uuid).must_equal "test-installation-uuid-123"
      _(company).must_be :active?
    end

    it "updates existing company when company already exists" do
      existing_company = Company.create!(
        fluid_shop: "unique-update-shop-456",
        name: "Old Name",
        fluid_company_id: 12345,
        company_droplet_uuid: "old-uuid",
        authentication_token: "unique-old-token",
        webhook_verification_token: "old-verify-token",
        active: false
      )

      company_data = {
        "fluid_shop" => "unique-update-shop-456",
        "name" => "Updated Shop",
        "fluid_company_id" => 12345,
        "droplet_uuid" => "new-uuid-123",
        "authentication_token" => "unique-new-auth-token",
        "webhook_verification_token" => "old-verify-token",
        "droplet_installation_uuid" => "new-installation-uuid-456",
      }

      payload = { "company" => company_data }

      _(-> { DropletInstalledJob.perform_now(payload) }).wont_change "Company.count"

      existing_company.reload
      _(existing_company.name).must_equal "Updated Shop"
      _(existing_company.company_droplet_uuid).must_equal "new-uuid-123"
      _(existing_company.authentication_token).must_equal "unique-new-auth-token"
      _(existing_company.webhook_verification_token).must_equal "old-verify-token"
      _(existing_company.droplet_installation_uuid).must_equal "new-installation-uuid-456"
      _(existing_company).must_be :active?
    end

    it "updates existing company even when webhook_verification_token is different" do
      existing_company = Company.create!(
        fluid_shop: "unique-skip-update-shop-789",
        name: "Original Name",
        fluid_company_id: 12345,
        company_droplet_uuid: "original-uuid",
        authentication_token: "unique-original-token",
        webhook_verification_token: "original-verify-token",
        active: true
      )

      company_data = {
        "fluid_shop" => "unique-skip-update-shop-789",
        "name" => "Attempted Update Name",
        "fluid_company_id" => 12345,
        "droplet_uuid" => "attempted-uuid",
        "authentication_token" => "unique-attempted-token",
        "webhook_verification_token" => "different-verify-token",
        "droplet_installation_uuid" => "attempted-installation-uuid",
      }

      payload = { "company" => company_data }

      # Job should run without changing company count but updating the company
      _(-> { DropletInstalledJob.perform_now(payload) }).wont_change "Company.count"

      existing_company.reload
      # Company should be updated despite different webhook_verification_token
      _(existing_company.name).must_equal "Attempted Update Name"
      _(existing_company.company_droplet_uuid).must_equal "attempted-uuid"
      _(existing_company.authentication_token).must_equal "unique-attempted-token"
      _(existing_company.webhook_verification_token).must_equal "different-verify-token"
      _(existing_company.droplet_installation_uuid).must_equal "attempted-installation-uuid"
      _(existing_company).must_be :active?
    end

    it "handles missing company droplet data" do
      # Empty payload
      payload = {}

      # Job should run without creating a company or raising errors
      _(-> { DropletInstalledJob.perform_now(payload) }).wont_change "Company.count"
    end

    it "handles invalid company data" do
      # Create invalid data (missing required fields)
      payload = {
        "company" => {
          "name" => "Invalid Company",
          # Missing required fields
        },
      }

      # Job should run without creating a company or raising errors
      _(-> { DropletInstalledJob.perform_now(payload) }).wont_change "Company.count"
    end

    it "registers callbacks when active callbacks exist" do
      # Create an active callback
      callback = ::Callback.create!(
        name: "test_callback",
        description: "Test callback",
        url: "https://example.com/callback",
        timeout_in_seconds: 10,
        active: true
      )

      company_data = {
        "fluid_shop" => "unique-callback-shop-789",
        "name" => "Callback Test Shop",
        "fluid_company_id" => 789,
        "droplet_uuid" => "callback-test-uuid",
        "authentication_token" => "unique-callback-auth-token",
        "webhook_verification_token" => "callback-verify-token",
        "droplet_installation_uuid" => "callback-installation-uuid",
      }

      payload = { "company" => company_data }

      # Job should run and create company even if callback registration fails
      _(-> { DropletInstalledJob.perform_now(payload) }).must_change "Company.count", +1

      # Check that the company was created
      company = Company.last
      _(company.fluid_shop).must_equal "unique-callback-shop-789"
      _(company.name).must_equal "Callback Test Shop"
    end

    it "handles callback registration errors gracefully" do
      # Create an active callback
      callback = ::Callback.create!(
        name: "test_callback",
        description: "Test callback",
        url: "https://example.com/callback",
        timeout_in_seconds: 10,
        active: true
      )

      company_data = {
        "fluid_shop" => "unique-error-shop-999",
        "name" => "Error Test Shop",
        "fluid_company_id" => 999,
        "droplet_uuid" => "error-test-uuid",
        "authentication_token" => "unique-error-auth-token",
        "webhook_verification_token" => "error-verify-token",
        "droplet_installation_uuid" => "error-installation-uuid",
      }

      payload = { "company" => company_data }

      # Job should run and create company even with callback errors
      _(-> { DropletInstalledJob.perform_now(payload) }).must_change "Company.count", +1

      # Check that the company was created
      company = Company.last
      _(company.fluid_shop).must_equal "unique-error-shop-999"
      _(company.name).must_equal "Error Test Shop"
    end

    it "handles no active callbacks" do
      # Ensure no active callbacks exist
      ::Callback.update_all(active: false)

      company_data = {
        "fluid_shop" => "unique-no-callback-shop-111",
        "name" => "No Callback Shop",
        "fluid_company_id" => 111,
        "droplet_uuid" => "no-callback-test-uuid",
        "authentication_token" => "unique-no-callback-auth-token",
        "webhook_verification_token" => "no-callback-verify-token",
        "droplet_installation_uuid" => "no-callback-installation-uuid",
      }

      payload = { "company" => company_data }

      # Job should run without any FluidClient calls
      _(-> { DropletInstalledJob.perform_now(payload) }).must_change "Company.count", +1

      # Check that the company was created without installed callback IDs
      company = Company.last
      _(company.installed_callback_ids).must_be_empty
    end

    it "uses company authentication token for FluidClient" do
      callback = ::Callback.create!(
        name: "test_callback",
        description: "Test callback",
        url: "https://example.com/callback",
        timeout_in_seconds: 10,
        active: true
      )

      company_data = {
        "fluid_shop" => "unique-auth-test-shop-222",
        "name" => "Auth Test Shop",
        "fluid_company_id" => 222,
        "droplet_uuid" => "auth-test-uuid",
        "authentication_token" => "unique-auth-test-token-123",
        "webhook_verification_token" => "auth-verify-token",
        "droplet_installation_uuid" => "auth-installation-uuid",
      }

      payload = { "company" => company_data }

      mock_client = Minitest::Mock.new
      mock_callback_registrations = Minitest::Mock.new

      mock_client.expect :callback_registrations, mock_callback_registrations
      mock_callback_registrations.expect :create, { "callback_registration" => { "uuid" => "test-uuid" } }

      captured_token = nil
      FluidClient.stub :new, ->(token) { captured_token = token; mock_client } do
        DropletInstalledJob.perform_now(payload)
      end

      assert_equal "unique-auth-test-token-123", captured_token
    end
  end
end
