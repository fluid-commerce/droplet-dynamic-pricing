require "test_helper"

describe Fluid::Carts do
  describe "Resource" do
    it "returns a resource" do
      Tasks::Settings.create_defaults
      client = FluidClient.new

      _(client.carts).must_be_instance_of Fluid::Carts::Resource
    end

    it "updates the volumes of a single cart item" do
      Tasks::Settings.create_defaults
      client = FluidClient.new
      cart_token = "ct_52blT6sVvSo4Ck2ygrKyW2"
      item_id = 674139
      volumes = { "cv" => 40, "qv" => 36 }
      expected_payload = { body: volumes }
      mock_response = { "success" => true }

      client.stub :patch, ->(path, options = {}) do
        _(path).must_equal "/api/carts/#{cart_token}/items/#{item_id}/update_volumes"
        _(options).must_equal expected_payload
        mock_response
      end do
        result = client.carts.update_item_volumes(cart_token, item_id, volumes)

        _(result).must_equal mock_response
      end
    end
  end
end
