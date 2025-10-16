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

    it "appends metadata to a customer" do
      Tasks::Settings.create_defaults
      client = FluidClient.new
      customer_id = 123
      metadata = { "customer_type" => "preferred_customer" }
      expected_payload = { body: { "metadata" => metadata } }
      mock_response = { "customer" => { "id" => customer_id } }

      client.stub :patch, ->(path, options = {}) do
        _(path).must_equal "/api/customers/#{customer_id}/append_metadata"
        _(options).must_equal expected_payload
        mock_response
      end do
        result = client.customers.append_metadata(customer_id, metadata)

        _(result).must_equal mock_response
      end
    end
  end
end
