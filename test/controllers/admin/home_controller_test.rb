require "test_helper"

describe Admin::HomeController do
  fixtures(:companies)

  describe "authentication" do
    it "allows access without authentication when dri is provided" do
      company = companies(:acme)
      get admin_home_index_path(dri: company.droplet_installation_uuid)

      must_respond_with :success
    end

    it "returns 404 when company is not found" do
      get admin_home_index_path(dri: "non-existent-uuid")

      must_respond_with :not_found
      _(response.body).must_include "Company not found"
    end

    it "works without user session" do
      company = companies(:acme)
      get admin_home_index_path(dri: company.droplet_installation_uuid)

      must_respond_with :success
    end
  end

  describe "with valid company" do
    it "displays stats for the company" do
      company = companies(:acme)

      get admin_home_index_path(dri: company.droplet_installation_uuid)

      must_respond_with :success
      _(response.body).must_include company.name
    end
  end
end
