require "test_helper"

describe Admin::TransactionsController do
  fixtures(:companies)

  describe "authentication" do
    it "allows access without authentication when dri is provided" do
      company = companies(:acme)
      get admin_transactions_path(dri: company.droplet_installation_uuid)

      must_respond_with :success
    end

    it "returns 404 when company is not found" do
      get admin_transactions_path(dri: "non-existent-uuid")

      must_respond_with :not_found
      _(response.body).must_include "Company not found"
    end

    it "works without user session" do
      company = companies(:acme)
      get admin_transactions_path(dri: company.droplet_installation_uuid)

      must_respond_with :success
    end
  end
end
