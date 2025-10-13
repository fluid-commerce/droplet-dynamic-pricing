require "test_helper"

describe PriceTypesController do
  fixtures(:companies)

  let(:company) { companies(:acme) }

  describe "POST /price_types" do
    it "creates a price type and redirects on success" do
      assert_difference -> { company.price_types.count }, +1 do
        post price_types_url, params: {
          dri: company.droplet_installation_uuid,
          price_type: { name: "Wholesale" },
        }
      end

      must_redirect_to price_types_url
      follow_redirect!
      _(response.body).must_include "Price type created"
    end

    it "renders new with 422 on validation failure" do
      assert_no_difference -> { company.price_types.count } do
        post price_types_url, params: {
          dri: company.droplet_installation_uuid,
          price_type: { name: "" },
        }
      end

      _(response.status).must_equal 422
      _(response.body).must_include "error"
    end
  end

  describe "PATCH /price_types/:id" do
    it "updates a price type and redirects on success" do
      price_type = company.price_types.create!(name: "Retail")

      patch price_type_url(price_type), params: {
        dri: company.droplet_installation_uuid,
        price_type: { name: "Wholesale" },
      }

      must_redirect_to price_types_url
      price_type.reload
      _(price_type.name).must_equal "Wholesale"

      follow_redirect!
      _(response.body).must_include "Price type updated"
    end

    it "renders edit with 422 on validation failure" do
      price_type = company.price_types.create!(name: "Retail")

      patch price_type_url(price_type), params: {
        dri: company.droplet_installation_uuid,
        price_type: { name: "" },
      }

      _(response.status).must_equal 422
      price_type.reload
      _(price_type.name).must_equal "Retail"
      _(response.body).must_include "error"
    end
  end
end


