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
        url: "https://test.example.com/callbacks/customer_logged_in",
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
        url: "https://test.example.com/callbacks/customer_logged_in",
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

    # The droplet has answered cart_customer_attached and cart_customer_detached
    # all along, but nothing ever created rows for them, so no install
    # registered either one and logout never reached the droplet.
    it "registers the cart customer attach and detach callbacks on install" do
      ::Callback.delete_all
      registered = []
      fake_registrations = Object.new
      fake_registrations.define_singleton_method(:create) do |attrs|
        registered << attrs[:definition_name]
        { "callback_registration" => { "uuid" => "reg-#{attrs[:definition_name]}" } }
      end
      fake_client = Object.new
      fake_client.define_singleton_method(:callback_registrations) { fake_registrations }
      fake_client.define_singleton_method(:webhooks) do
        w = Object.new
        w.define_singleton_method(:create) { |_a| { "webhook" => { "id" => 1 } } }
        w
      end

      payload = { "company" => {
        "fluid_shop" => "attach-detach-shop",
        "name" => "Attach Detach Shop",
        "fluid_company_id" => 909,
        "droplet_uuid" => "attach-detach-uuid",
        "authentication_token" => "attach-detach-token",
        "webhook_verification_token" => "attach-detach-verify",
        "droplet_installation_uuid" => "attach-detach-installation",
      } }

      FluidClient.stub(:new, fake_client) do
        DropletInstalledJob.perform_now(payload)
      end

      _(registered).must_include "cart_customer_attached"
      _(registered).must_include "cart_customer_detached"
    end

    it "registers every callback this droplet serves, not just the ones someone activated" do
      ::Callback.delete_all
      registered = []
      fake_registrations = Object.new
      fake_registrations.define_singleton_method(:create) do |attrs|
        registered << attrs[:definition_name]
        { "callback_registration" => { "uuid" => "reg-#{attrs[:definition_name]}" } }
      end
      fake_client = Object.new
      fake_client.define_singleton_method(:callback_registrations) { fake_registrations }
      fake_client.define_singleton_method(:webhooks) do
        w = Object.new
        w.define_singleton_method(:create) { |_a| { "webhook" => { "id" => 1 } } }
        w
      end

      payload = { "company" => {
        "fluid_shop" => "all-served-shop",
        "name" => "All Served Shop",
        "fluid_company_id" => 910,
        "droplet_uuid" => "all-served-uuid",
        "authentication_token" => "all-served-token",
        "webhook_verification_token" => "all-served-verify",
        "droplet_installation_uuid" => "all-served-installation",
      } }

      FluidClient.stub(:new, fake_client) do
        DropletInstalledJob.perform_now(payload)
      end

      _(registered.sort).must_equal ::Callback::SERVED_PATHS.keys.sort
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
        url: "https://test.example.com/callbacks/customer_logged_in",
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

      registration_response = { "callback_registration" => { "uuid" => "test-uuid" } }
      mock_client.expect :callback_registrations, mock_callback_registrations
      mock_callback_registrations.expect :create, registration_response do |attributes|
        attributes[:definition_name] == "test_callback" &&
          attributes[:url] == "https://test.example.com/callbacks/customer_logged_in"
      end

      captured_token = nil
      FluidClient.stub :new, ->(token, **) { captured_token = token; mock_client } do
        DropletInstalledJob.perform_now(payload)
      end

      assert_equal "unique-auth-test-token-123", captured_token
      mock_client.verify
      mock_callback_registrations.verify
    end

    it "refuses to register an active callback whose URL this droplet does not serve" do
      stale_callback = ::Callback.create!(
        name: "stale_callback",
        description: "Handler deleted after activation",
        url: "https://test.example.com/callbacks/customer_logged_in",
        timeout_in_seconds: 10,
        active: true
      )
      stale_callback.update_column(:url, "https://test.example.com/callbacks/verify_email_success")

      company_data = {
        "fluid_shop" => "stale-callback-shop",
        "name" => "Stale Callback Shop",
        "fluid_company_id" => 444,
        "droplet_uuid" => "stale-callback-uuid",
        "authentication_token" => "stale-callback-token",
        "webhook_verification_token" => "stale-callback-verify",
        "droplet_installation_uuid" => "stale-callback-installation",
      }

      captured_attributes = []
      registrations = Object.new
      registrations.define_singleton_method(:create) do |attributes|
        captured_attributes << attributes
        { "callback_registration" => { "uuid" => "uuid-#{captured_attributes.size}" } }
      end
      client = Object.new
      client.define_singleton_method(:callback_registrations) { registrations }

      FluidClient.stub :new, ->(_token) { client } do
        DropletInstalledJob.perform_now({ "company" => company_data })
      end

      registered_names = captured_attributes.map { |attributes| attributes[:definition_name] }
      refute_includes registered_names, "stale_callback"
      # The served callbacks still register — the refusal is targeted at the row
      # whose URL this droplet cannot answer, not a blanket abort.
      _(registered_names.sort).must_equal ::Callback::SERVED_PATHS.keys.sort
    end

    it "merges newly installed callback ids with those already recorded" do
      ::Callback.create!(
        name: "test_callback",
        description: "Test callback",
        url: "https://test.example.com/callbacks/customer_logged_in",
        timeout_in_seconds: 10,
        active: true
      )

      Company.create!(
        fluid_shop: "merge-ids-shop",
        name: "Merge Ids Shop",
        fluid_company_id: 555,
        company_droplet_uuid: "merge-ids-uuid",
        authentication_token: "merge-ids-token",
        webhook_verification_token: "merge-ids-verify",
        active: true,
        installed_callback_ids: %w[cbr_previous]
      )

      company_data = {
        "fluid_shop" => "merge-ids-shop",
        "name" => "Merge Ids Shop",
        "fluid_company_id" => 555,
        "droplet_uuid" => "merge-ids-uuid",
        "authentication_token" => "merge-ids-token",
        "webhook_verification_token" => "merge-ids-verify",
        "droplet_installation_uuid" => "merge-ids-installation",
      }

      registrations = Object.new
      registrations.define_singleton_method(:create) do |_attributes|
        { "callback_registration" => { "uuid" => "cbr_fresh" } }
      end
      client = Object.new
      client.define_singleton_method(:callback_registrations) { registrations }

      FluidClient.stub :new, ->(_token) { client } do
        DropletInstalledJob.perform_now({ "company" => company_data })
      end

      installed_ids = Company.find_by(fluid_shop: "merge-ids-shop").installed_callback_ids
      _(installed_ids).must_equal %w[cbr_previous cbr_fresh]
    end

    it "registers only routed subscription webhooks, never subscription.updated" do
      ::Callback.update_all(active: false)

      company_data = {
        "fluid_shop" => "webhook-events-shop",
        "name" => "Webhook Events Shop",
        "fluid_company_id" => 666,
        "droplet_uuid" => "webhook-events-uuid",
        "authentication_token" => "webhook-events-token",
        "webhook_verification_token" => "webhook-events-verify",
        "droplet_installation_uuid" => "webhook-events-installation",
      }

      captured_events = []
      webhooks = Object.new
      webhooks.define_singleton_method(:create) do |attributes|
        captured_events << attributes[:event]
        { "webhook" => { "id" => "wh-#{captured_events.size}" } }
      end
      client = Object.new
      client.define_singleton_method(:webhooks) { webhooks }

      FluidClient.stub :new, ->(_token) { client } do
        DropletInstalledJob.perform_now({ "company" => company_data })
      end

      _(captured_events.sort).must_equal %w[cancelled paused reactivated resumed started]
    end

    # STU2-3108. Fluid reads country_codes as a delivery filter, inverted from how
    # it reads: a dispatch carrying no country matches ONLY registrations whose
    # country_codes is empty (Callback::Registration.scoped_to_country), and none
    # of the Callback::Client.notify callers carry one — cart_country_changed
    # included. Listing this droplet's countries here would stop that callback
    # arriving, silently. Pinned because the omission is a decision, not an
    # oversight, and nothing else in the code says so.
    it "registers callbacks globally, never scoped to countries" do
      ::Callback.create!(
        name: "cart_country_changed",
        description: "Cart country changed",
        url: "https://test.example.com/callbacks/cart_country_changed",
        timeout_in_seconds: 10,
        active: true
      )

      company_data = {
        "fluid_shop" => "global-scope-shop",
        "name" => "Global Scope Shop",
        "fluid_company_id" => 333,
        "droplet_uuid" => "global-scope-uuid",
        "authentication_token" => "global-scope-token",
        "webhook_verification_token" => "global-scope-verify",
        "droplet_installation_uuid" => "global-scope-installation",
      }

      captured_attributes = []
      registrations = Object.new
      registrations.define_singleton_method(:create) do |attributes|
        captured_attributes << attributes
        { "callback_registration" => { "uuid" => "uuid-#{captured_attributes.size}" } }
      end
      client = Object.new
      client.define_singleton_method(:callback_registrations) { registrations }

      FluidClient.stub :new, ->(_token, **) { client } do
        DropletInstalledJob.perform_now({ "company" => company_data })
      end

      assert captured_attributes.any?, "expected at least one callback to be registered"
      captured_attributes.each do |attributes|
        refute attributes.key?(:country_codes),
               "#{attributes[:definition_name]} must register globally: a country-scoped " \
               "registration receives no notify-dispatched callback at all"
        refute attributes.key?("country_codes")
      end
    end
  end
end
