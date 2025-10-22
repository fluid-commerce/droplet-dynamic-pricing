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
    it "redirects to index with notice on success" do
      price_type = company.price_types.create!(name: "Retail")

      PriceTypeUseCases::Update.stub :call, ->(**_kwargs) { { success: true, price_type: price_type } } do
        patch price_type_url(price_type), params: {
          dri: company.droplet_installation_uuid,
          price_type: { name: "Wholesale" },
        }
      end

      must_redirect_to price_types_url
      follow_redirect!
      _(response.body).must_include "Price type updated"
    end

    it "redirects to index with alert on failure" do
      price_type = company.price_types.create!(name: "Retail")

      PriceTypeUseCases::Update.stub :call, ->(**_kwargs) {
 { success: false, error: "Cannot update price type: it is in use by one or more customers" } } do
        patch price_type_url(price_type), params: {
          dri: company.droplet_installation_uuid,
          price_type: { name: "Wholesale" },
        }
      end

      must_redirect_to price_types_url
      follow_redirect!
      _(response.body).must_include "Cannot update price type: it is in use by one or more customers"
    end
  end

  describe "DELETE /price_types/:id" do
    it "redirects to index with notice on success" do
      price_type = company.price_types.create!(name: "Retail")

      PriceTypeUseCases::Delete.stub :call, ->(**_kwargs) { { success: true } } do
        delete price_type_url(price_type), params: {
          dri: company.droplet_installation_uuid,
        }
      end

      must_redirect_to price_types_url
      follow_redirect!
      _(response.body).must_include "Price type deleted"
    end

    it "redirects to index with alert on failure" do
      price_type = company.price_types.create!(name: "Retail")

      PriceTypeUseCases::Delete.stub :call, ->(**_kwargs) {
 { success: false, error: "Cannot delete price type: it is in use by one or more customers" } } do
        delete price_type_url(price_type), params: {
          dri: company.droplet_installation_uuid,
        }
      end

      must_redirect_to price_types_url
      follow_redirect!
      _(response.body).must_include "Cannot delete price type: it is in use by one or more customers"
    end
  end
end
