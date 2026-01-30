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
end
