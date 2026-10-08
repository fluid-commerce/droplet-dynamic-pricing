require "test_helper"

describe Admin::IntegrationSettingsController do
  fixtures(:companies)

  describe "authentication" do
    it "allows access to show without authentication when dri is provided" do
      company = companies(:acme)
      get admin_integration_setting_path(dri: company.droplet_installation_uuid)

      must_respond_with :success
    end

    it "allows access to edit without authentication when dri is provided" do
      company = companies(:acme)
      get edit_admin_integration_setting_path(dri: company.droplet_installation_uuid)

      must_respond_with :success
    end

    it "allows update without authentication when dri is provided" do
      company = companies(:acme)
      integration_setting = IntegrationSetting.create!(
        company: company,
        enabled: false,
        credentials: {},
        settings: {}
      )

      patch admin_integration_setting_path(dri: company.droplet_installation_uuid), params: {
        integration_setting: {
          enabled: true,
          credentials: {
            exigo_db_host: "test.example.com",
            exigo_db_username: "user",
            exigo_db_password: "pass",
            exigo_db_name: "db",
            api_base_url: "https://api.example.com",
            api_username: "api_user",
            api_password: "api_pass",
          },
          settings: {},
        },
      }

      must_respond_with :redirect
      integration_setting.reload
      _(integration_setting.enabled).must_equal true
    end

    it "persists the adjust_volumes_for_subscription toggle" do
      company = companies(:acme)
      integration_setting = IntegrationSetting.create!(
        company: company,
        enabled: false,
        credentials: {},
        settings: {}
      )

      patch admin_integration_setting_path(dri: company.droplet_installation_uuid), params: {
        integration_setting: {
          enabled: true,
          settings: { adjust_volumes_for_subscription: "1" },
        },
      }

      must_respond_with :redirect
      integration_setting.reload
      _(integration_setting.adjust_volumes_for_subscription?).must_equal true
    end

    it "persists the subscription_volume_source setting" do
      company = companies(:acme)
      integration_setting = IntegrationSetting.create!(
        company: company,
        enabled: false,
        credentials: {},
        settings: {}
      )

      patch admin_integration_setting_path(dri: company.droplet_installation_uuid), params: {
        integration_setting: {
          enabled: true,
          settings: { subscription_volume_source: "preferred_customer" },
        },
      }

      must_respond_with :redirect
      integration_setting.reload
      _(integration_setting.subscription_volume_source).must_equal "preferred_customer"
    end

    it "persists the exigo_preferred_signal setting" do
      company = companies(:acme)
      integration_setting = IntegrationSetting.create!(
        company: company,
        enabled: false,
        credentials: {},
        settings: {}
      )

      patch admin_integration_setting_path(dri: company.droplet_installation_uuid), params: {
        integration_setting: {
          enabled: true,
          settings: { exigo_preferred_signal: "customer_type" },
        },
      }

      must_respond_with :redirect
      integration_setting.reload
      _(integration_setting.exigo_preferred_signal).must_equal "customer_type"
    end

    it "persists the preferred_source setting" do
      company = companies(:acme)
      integration_setting = IntegrationSetting.create!(
        company: company,
        enabled: false,
        credentials: {},
        settings: {}
      )

      patch admin_integration_setting_path(dri: company.droplet_installation_uuid), params: {
        integration_setting: {
          enabled: true,
          settings: { preferred_source: "fluid_member_type" },
        },
      }

      must_respond_with :redirect
      integration_setting.reload
      _(integration_setting.preferred_source).must_equal "fluid_member_type"
    end

    it "persists the promote_member_type_on_first_subscription toggle" do
      company = companies(:acme)
      integration_setting = IntegrationSetting.create!(
        company: company,
        enabled: false,
        credentials: {},
        settings: {}
      )

      patch admin_integration_setting_path(dri: company.droplet_installation_uuid), params: {
        integration_setting: {
          enabled: true,
          settings: { promote_member_type_on_first_subscription: "1" },
        },
      }

      must_respond_with :redirect
      integration_setting.reload
      _(integration_setting.promote_member_type_on_first_subscription?).must_equal true
    end

    it "returns 404 when company is not found" do
      get admin_integration_setting_path(dri: "non-existent-uuid")

      must_respond_with :not_found
      _(response.body).must_include "Company not found"
    end

    it "works without user session" do
      company = companies(:acme)
      get admin_integration_setting_path(dri: company.droplet_installation_uuid)

      must_respond_with :success
    end
  end

  describe "test_connection" do
    def configure(company)
      IntegrationSetting.create!(
        company: company,
        enabled: true,
        credentials: {
          exigo_db_host: "1160-drsql.epic-ha.com",
          exigo_db_username: "Yoli_FluidProd",
          exigo_db_password: "db-secret",
          exigo_db_name: "YoliReporting",
          api_base_url: "https://yoli-api.exigo.com/3.0",
          api_username: "api_user",
          api_password: "api-secret",
        },
        settings: {}
      )
    end

    it "shows both checks with the saved credentials" do
      company = companies(:acme)
      configure(company)
      client = Struct.new(:check_database, :check_api).new(
        { ok: false, message: "Login failed for user 'Yoli_FluidProd'." },
        { ok: true, message: "Authenticated (HTTP 404 from yoli-api.exigo.com in 120 ms)" },
      )

      ExigoClient.stub(:for_company, client) do
        post test_connection_admin_integration_setting_path(dri: company.droplet_installation_uuid)
      end

      must_respond_with :success
      _(response.body).must_include "Login failed for user &#39;Yoli_FluidProd&#39;."
      _(response.body).must_include "Authenticated (HTTP 404"
      _(response.body).wont_include "db-secret"
      _(response.body).wont_include "api-secret"
    end

    it "says the integration is not configured instead of trying to connect" do
      company = companies(:acme)

      post test_connection_admin_integration_setting_path(dri: company.droplet_installation_uuid)

      must_respond_with :success
      _(response.body).must_include "Exigo database credentials not configured"
      _(response.body).must_include "Exigo API credentials not configured"
    end

    it "returns 404 when company is not found" do
      post test_connection_admin_integration_setting_path(dri: "non-existent-uuid")

      must_respond_with :not_found
    end

    it "offers the button once credentials are saved" do
      company = companies(:acme)
      configure(company)

      get admin_integration_setting_path(dri: company.droplet_installation_uuid)

      _(response.body).must_include "Test connection"
    end
  end
end
