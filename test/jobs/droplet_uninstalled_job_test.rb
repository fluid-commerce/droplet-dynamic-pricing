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
      FluidClient.stub :new, ->(token, **) { captured_token = token; mock_client } do
        DropletUninstalledJob.perform_now(payload)
      end

      assert_equal company.authentication_token, captured_token
    end
  end
end
