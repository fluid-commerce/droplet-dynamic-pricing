require "test_helper"

describe Fluid::Variants do
  describe "Resource" do
    it "returns a resource" do
      Tasks::Settings.create_defaults
      client = FluidClient.new

      _(client.variants).must_be_instance_of Fluid::Variants::Resource
    end

    it "gets a variant by id" do
      Tasks::Settings.create_defaults
      client = FluidClient.new
      variant_id = 555
      mock_response = {
        "variant" => {
          "id" => variant_id,
          "variant_countries" => [ { "country_code" => "US", "cv" => 50, "qv" => 45 } ],
        },
      }

      client.stub :get, ->(path, _options = {}) do
        _(path).must_equal "/api/company/v1/variants/#{variant_id}"
        mock_response
      end do
        result = client.variants.get(variant_id)

        _(result).must_equal mock_response
      end
    end
  end
end
