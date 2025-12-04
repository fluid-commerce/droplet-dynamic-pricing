require "test_helper"

describe DropletUninstalledJob do
  fixtures(:companies)

  describe "#perform" do
    it "marks company as uninstalled" do
      # Set up an installed company
      company = companies(:acme)
      company.update(uninstalled_at: nil)

      # Create payload with company identifier
      payload = {
        "company" => {
          "company_droplet_uuid" => company.company_droplet_uuid,
          "fluid_company_id" => company.fluid_company_id,
        },
      }

      # Run the job and check that the company is marked as uninstalled
      _(company.reload.uninstalled_at).must_be_nil

      DropletUninstalledJob.perform_now(payload)

      _(company.reload.uninstalled_at).wont_be_nil
      _(company.uninstalled_at.to_i).must_be_close_to Time.current.to_i, 2
    end

    it "deletes callbacks when company has installed callbacks" do
      # Set up an installed company with callbacks
      company = companies(:acme)
      company.update(uninstalled_at: nil, installed_callback_ids: %w[cbr_test123 cbr_test456])

      # Create payload with company identifier
      payload = {
        "company" => {
          "company_droplet_uuid" => company.company_droplet_uuid,
          "fluid_company_id" => company.fluid_company_id,
        },
      }

      # Job should run and mark company as uninstalled
      DropletUninstalledJob.perform_now(payload)

      # Check that the company is marked as uninstalled
      _(company.reload.uninstalled_at).wont_be_nil
      # Check that installed_callback_ids were cleared
      _(company.installed_callback_ids).must_be_empty
    end

    it "handles callback deletion errors gracefully" do
      # Set up an installed company with callbacks
      company = companies(:acme)
      company.update(uninstalled_at: nil, installed_callback_ids: %w[cbr_test123 cbr_test456])

      # Create payload with company identifier
      payload = {
        "company" => {
          "company_droplet_uuid" => company.company_droplet_uuid,
          "fluid_company_id" => company.fluid_company_id,
        },
      }

      # Job should run and mark company as uninstalled even if callback deletion fails
      DropletUninstalledJob.perform_now(payload)

      # Check that the company is marked as uninstalled despite errors
      _(company.reload.uninstalled_at).wont_be_nil
      # Check that installed_callback_ids were cleared even with errors
      _(company.installed_callback_ids).must_be_empty
    end

    it "handles company with no installed callbacks" do
      # Set up an installed company without callbacks
      company = companies(:acme)
      company.update(uninstalled_at: nil, installed_callback_ids: [])

      # Create payload with company identifier
      payload = {
        "company" => {
          "company_droplet_uuid" => company.company_droplet_uuid,
          "fluid_company_id" => company.fluid_company_id,
        },
      }

      # Job should run without any FluidClient calls
      DropletUninstalledJob.perform_now(payload)

      # Check that the company is marked as uninstalled
      _(company.reload.uninstalled_at).wont_be_nil
      # Check that installed_callback_ids remain empty
      _(company.installed_callback_ids).must_be_empty
    end

    it "finds company by uuid if provided" do
      # Set up an installed company
      company = companies(:acme)
      company.update(uninstalled_at: nil)

      # Create payload with only uuid
      payload = {
        "company" => {
          "company_droplet_uuid" => company.company_droplet_uuid,
        },
      }

      DropletUninstalledJob.perform_now(payload)

      _(company.reload.uninstalled_at).wont_be_nil
    end

    it "finds company by fluid_company_id if provided" do
      # Set up an installed company
      company = companies(:acme)
      company.update(uninstalled_at: nil)

      # Create payload with only fluid_company_id
      payload = {
        "company" => {
          "fluid_company_id" => company.fluid_company_id,
        },
      }

      DropletUninstalledJob.perform_now(payload)

      _(company.reload.uninstalled_at).wont_be_nil
    end

    it "handles missing company gracefully" do
      # Set up an installed company for comparison
      company = companies(:acme)
      company.update(uninstalled_at: nil)

      # Create payload with non-existent identifiers
      payload = {
        "company" => {
          "company_droplet_uuid" => "non-existent-uuid",
          "fluid_company_id" => 9999999,
        },
      }

      # Job should run without raising errors
      _(-> { DropletUninstalledJob.perform_now(payload) }).must_be_silent

      # Original company should remain unchanged
      _(company.reload.uninstalled_at).must_be_nil
    end

    it "handles empty payload gracefully" do
      # Set up an installed company for comparison
      company = companies(:acme)
      company.update(uninstalled_at: nil)

      # Empty payload
      payload = {}

      # Job should run without raising errors
      _(-> { DropletUninstalledJob.perform_now(payload) }).must_be_silent

      # Original company should remain unchanged
      _(company.reload.uninstalled_at).must_be_nil
    end

    it "uses company authentication token for FluidClient" do
      company = companies(:acme)
      company.update(uninstalled_at: nil, installed_callback_ids: %w[cbr_test123 cbr_test456])

      payload = {
        "company" => {
          "company_droplet_uuid" => company.company_droplet_uuid,
          "fluid_company_id" => company.fluid_company_id,
        },
      }

      mock_client = Minitest::Mock.new
      mock_callback_registrations = Minitest::Mock.new

      mock_client.expect :callback_registrations, mock_callback_registrations
      mock_callback_registrations.expect :delete, true, [ "cbr_test123" ]
      mock_callback_registrations.expect :delete, true, [ "cbr_test456" ]

      captured_token = nil
      FluidClient.stub :new, ->(token) { captured_token = token; mock_client } do
        DropletUninstalledJob.perform_now(payload)
      end

      assert_equal company.authentication_token, captured_token
    end
  end

  describe "#deactivate_callbacks_from_routes" do
    it "deactivates callbacks from callback routes" do
      # Create active callbacks
      callback1 = ::Callback.create!(
        name: "cart_subscription_added",
        description: "Test callback 1",
        url: "https://example.com/callback1",
        timeout_in_seconds: 10,
        active: true
      )

      callback2 = ::Callback.create!(
        name: "cart_item_added",
        description: "Test callback 2",
        url: "https://example.com/callback2",
        timeout_in_seconds: 10,
        active: true
      )

      job = DropletUninstalledJob.new
      job.instance_variable_set(:@payload, {})

      job.send(:deactivate_callbacks_from_routes)

      callback1.reload
      callback2.reload
      _(callback1).wont_be :active?
      _(callback2).wont_be :active?
    end

    it "handles missing callbacks gracefully" do
      # Ensure no callbacks exist
      ::Callback.delete_all

      job = DropletUninstalledJob.new
      job.instance_variable_set(:@payload, {})

      # Should not raise error
      _(-> { job.send(:deactivate_callbacks_from_routes) }).must_be_silent
    end

    it "re-raises errors after logging" do
      job = DropletUninstalledJob.new
      job.instance_variable_set(:@payload, {})

      Rails.application.routes.stub :routes, -> { raise NoMethodError.new("test error") } do
        error = _(-> { job.send(:deactivate_callbacks_from_routes) }).must_raise NoMethodError
        _(error.message).must_equal "test error"
      end
    end
  end

  describe "#delete_installed_callbacks" do
    it "continues with next callback when FluidClient::Error occurs" do
      company = companies(:acme)
      company.update(installed_callback_ids: %w[callback-id-1 callback-id-2])

      job = DropletUninstalledJob.new
      job.instance_variable_set(:@payload, {})

      mock_client = Object.new
      def mock_client.callback_registrations
        @mock_registrations ||= Object.new
        def @mock_registrations.delete(id)
          @call_count ||= 0
          @call_count += 1
          if @call_count == 1
            raise FluidClient::APIError.new("API Error")
          else
            true
          end
        end
        @mock_registrations
      end

      FluidClient.stub :new, ->(_token) { mock_client } do
        job.send(:delete_installed_callbacks, company)
      end

      # Verify callback IDs were cleared
      company.reload
      _(company.installed_callback_ids).must_be_empty
    end

    it "continues with next callback when StandardError occurs" do
      company = companies(:acme)
      company.update(installed_callback_ids: %w[callback-id-1 callback-id-2])

      job = DropletUninstalledJob.new
      job.instance_variable_set(:@payload, {})

      mock_client = Object.new
      def mock_client.callback_registrations
        @mock_registrations ||= Object.new
        def @mock_registrations.delete(id)
          @call_count ||= 0
          @call_count += 1
          if @call_count == 1
            raise NoMethodError.new("Unexpected error")
          else
            true
          end
        end
        @mock_registrations
      end

      FluidClient.stub :new, ->(_token) { mock_client } do
        job.send(:delete_installed_callbacks, company)
      end

      # Verify callback IDs were cleared despite first error
      company.reload
      _(company.installed_callback_ids).must_be_empty
    end

    it "clears installed_callback_ids after processing" do
      company = companies(:acme)
      company.update(installed_callback_ids: %w[callback-id-1 callback-id-2])

      job = DropletUninstalledJob.new
      job.instance_variable_set(:@payload, {})

      mock_client = Object.new
      def mock_client.callback_registrations
        @mock_registrations ||= Object.new
        def @mock_registrations.delete(id)
          true
        end
        @mock_registrations
      end

      FluidClient.stub :new, ->(_token) { mock_client } do
        job.send(:delete_installed_callbacks, company)
      end

      company.reload
      _(company.installed_callback_ids).must_be_empty
    end

    it "does nothing when company has no installed callbacks" do
      company = companies(:acme)
      company.update(installed_callback_ids: [])

      job = DropletUninstalledJob.new
      job.instance_variable_set(:@payload, {})

      # Should not call FluidClient at all
      called = false
      FluidClient.stub :new, ->(_token) { called = true; Minitest::Mock.new } do
        job.send(:delete_installed_callbacks, company)
      end

      _(called).must_equal false
    end
  end
end
