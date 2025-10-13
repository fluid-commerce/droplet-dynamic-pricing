require "test_helper"

describe Fluid::Customers do
  describe "Resource" do
    it "returns a resource" do
      Tasks::Settings.create_defaults
      client = FluidClient.new

      _(client.customers).must_be_instance_of Fluid::Customers::Resource
    end

    it "gets customers" do
      Tasks::Settings.create_defaults
      client = FluidClient.new
      mock_response = { "customers" => [] }

      client.stub :get, mock_response do
        result = client.customers.get

        _(result).must_equal mock_response
      end
    end
  end
end
