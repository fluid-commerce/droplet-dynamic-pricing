require "test_helper"

describe AdminApi::CompaniesController do
  fixtures(:companies)

  ADMIN_TOKEN = "test-admin-token".freeze

  before do
    ENV["ADMIN_API_TOKEN"] = ADMIN_TOKEN
  end

  def auth_headers(token = ADMIN_TOKEN)
    { "Authorization" => "Bearer #{token}" }
  end

  describe "auth" do
    it "returns 401 when the bearer token is missing" do
      company = companies(:acme)
      patch admin_api_company_url,
            params: { fluid_company_id: company.fluid_company_id, name: "x" },
            as: :json
      _(response.status).must_equal 401
    end

    it "returns 401 when the bearer token is wrong" do
      company = companies(:acme)
      patch admin_api_company_url,
            params: { fluid_company_id: company.fluid_company_id, name: "x" },
            headers: auth_headers("wrong-token"),
            as: :json
      _(response.status).must_equal 401
    end
  end

  describe "validation" do
    it "returns 422 when no mutable field is provided" do
      company = companies(:acme)
      patch admin_api_company_url,
            params: { fluid_company_id: company.fluid_company_id },
            headers: auth_headers,
            as: :json
      _(response.status).must_equal 422
    end

    it "returns 422 when neither fluid_company_id nor id is provided" do
      patch admin_api_company_url,
            params: { name: "x" },
            headers: auth_headers,
            as: :json
      _(response.status).must_equal 422
    end
  end

  describe "not found" do
    it "returns 404 when no company matches fluid_company_id" do
      patch admin_api_company_url,
            params: { fluid_company_id: 999_999_999, name: "x" },
            headers: auth_headers,
            as: :json
      _(response.status).must_equal 404
    end
  end

  describe "update" do
    it "renames a company (name + fluid_shop)" do
      company = companies(:acme)
      patch admin_api_company_url,
            params: {
              fluid_company_id: company.fluid_company_id,
              name: "New Name",
              fluid_shop: "new-shop.fluid.app",
            },
            headers: auth_headers,
            as: :json

      _(response.status).must_equal 200
      company.reload
      _(company.name).must_equal "New Name"
      _(company.fluid_shop).must_equal "new-shop.fluid.app"
    end

    it "deactivates a stale install (active: false) without touching other fields" do
      company = companies(:acme)
      original_name = company.name

      patch admin_api_company_url,
            params: { fluid_company_id: company.fluid_company_id, active: false },
            headers: auth_headers,
            as: :json

      _(response.status).must_equal 200
      company.reload
      _(company.active).must_equal false
      _(company.name).must_equal original_name
    end

    it "updates by explicit id" do
      company = companies(:globex)
      patch admin_api_company_url,
            params: { id: company.id, name: "Globex Renamed" },
            headers: auth_headers,
            as: :json

      _(response.status).must_equal 200
      _(company.reload.name).must_equal "Globex Renamed"
    end
  end

  describe "non-unique fluid_company_id guard" do
    it "returns 409 with candidate ids when fluid_company_id matches multiple rows" do
      shared_id = 555_000_111
      a = Company.create!(
        name: "Dup A", fluid_shop: "dup-a", authentication_token: "dup-a-token",
        fluid_company_id: shared_id, company_droplet_uuid: "dup-a-uuid", active: true
      )
      b = Company.create!(
        name: "Dup B", fluid_shop: "dup-b", authentication_token: "dup-b-token",
        fluid_company_id: shared_id, company_droplet_uuid: "dup-b-uuid", active: true
      )

      patch admin_api_company_url,
            params: { fluid_company_id: shared_id, active: false },
            headers: auth_headers,
            as: :json

      _(response.status).must_equal 409
      body = JSON.parse(response.body)
      candidate_ids = body["candidates"].map { |c| c["id"] }
      _(candidate_ids).must_include a.id
      _(candidate_ids).must_include b.id
      # Nothing was mutated.
      _(a.reload.active).must_equal true
      _(b.reload.active).must_equal true
    end
  end
end
