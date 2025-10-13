require "test_helper"

describe FluidClient do
  describe "Included modules" do
    it "includes Fluid::Droplets" do
      assert_includes FluidClient.included_modules, Fluid::Droplets
    end

    it "includes Fluid::Webhooks" do
      assert_includes FluidClient.included_modules, Fluid::Webhooks
    end

    it "includes Fluid::CallbackDefinitions" do
      assert_includes FluidClient.included_modules, Fluid::CallbackDefinitions
    end

    it "includes Fluid::CallbackRegistrations" do
      assert_includes FluidClient.included_modules, Fluid::CallbackRegistrations
    end

    it "includes Fluid::Customers" do
      assert_includes FluidClient.included_modules, Fluid::Customers
    end
  end

  describe "initialization and headers" do
    it "sets headers with auth token when initialized with token" do
      client = FluidClient.new("test_token_123")

      assert_equal "Bearer test_token_123", FluidClient.headers["Authorization"]
      assert_equal "application/json", FluidClient.headers["Content-Type"]
    end

    it "sets headers with nil token when initialized without token" do
      client = FluidClient.new

      assert_equal "Bearer ", FluidClient.headers["Authorization"]
      assert_equal "application/json", FluidClient.headers["Content-Type"]
    end

    it "updates headers when creating multiple instances with different tokens" do
      client1 = FluidClient.new("token1")
      assert_equal "Bearer token1", FluidClient.headers["Authorization"]

      client2 = FluidClient.new("token2")
      assert_equal "Bearer token2", FluidClient.headers["Authorization"]

      assert_equal "token1", client1.instance_variable_get(:@auth_token)
      assert_equal "token2", client2.instance_variable_get(:@auth_token)
    end

    it "calls update_headers during initialization" do
      client = FluidClient.new("test_token")

      assert_equal "Bearer test_token", FluidClient.headers["Authorization"]
    end
  end
  describe "#payload" do
    it "returns a valid payload" do
      Tasks::Settings.create_defaults
      client = FluidClient.new

      _(client.droplets.payload).must_equal({
        "droplet" => {
          "name" => "Existing Droplet",
          "uuid" => "existing-uuid",
          "active" => true,
          "embed_url" => "https://example.com/existing",
          "settings" => {
            "marketplace_page" => {
              "title" => "Marketplace Title",
              "logo_url" => nil,
              "summary" => nil,
            },
            "details_page" => {
              "title" => "Details Title",
              "logo_url" => nil,
              "summary" => nil,
            },
            "service_operational_countries" => [],
          },
        },
      })
    end
  end

  describe "callback_definitions" do
    it "returns callback_definitions resource" do
      Tasks::Settings.create_defaults
      client = FluidClient.new

      _(client.callback_definitions).must_be_instance_of Fluid::CallbackDefinitions::Resource
    end

    it "gets callback definitions" do
      Tasks::Settings.create_defaults
      client = FluidClient.new
      mock_response = { "definitions" => [] }

      client.stub :get, mock_response do
        result = client.callback_definitions.get

        _(result).must_equal mock_response
      end
    end
  end

  describe "callback_registrations" do
    it "returns callback_registrations resource" do
      Tasks::Settings.create_defaults
      client = FluidClient.new

      _(client.callback_registrations).must_be_instance_of Fluid::CallbackRegistrations::Resource
    end

    it "gets callback registrations without params" do
      Tasks::Settings.create_defaults
      client = FluidClient.new
      mock_response = { "callback_registrations" => [] }

      client.stub :get, mock_response do
        result = client.callback_registrations.get

        _(result).must_equal mock_response
      end
    end

    it "gets callback registrations with query params" do
      Tasks::Settings.create_defaults
      client = FluidClient.new
      mock_response = { "callback_registrations" => [] }
      params = { active: true, company_id: 123, page: 1, per_page: 50 }

      client.stub :get, mock_response do
        result = client.callback_registrations.get(params)

        _(result).must_equal mock_response
      end
    end

    it "creates callback registration" do
      Tasks::Settings.create_defaults
      client = FluidClient.new
      mock_response = { "callback_registration" => { "id" => "reg-123" } }
      attributes = {
        definition_name: "test_callback",
        url: "https://example.com/callback",
        timeout_in_seconds: 30,
        active: true,
      }

      client.stub :post, mock_response do
        result = client.callback_registrations.create(attributes)

        _(result).must_equal mock_response
      end
    end

    it "shows callback registration" do
      Tasks::Settings.create_defaults
      client = FluidClient.new
      mock_response = { "callback_registration" => { "id" => "reg-456" } }
      uuid = "reg-456"

      client.stub :get, mock_response do
        result = client.callback_registrations.show(uuid)

        _(result).must_equal mock_response
      end
    end

    it "updates callback registration" do
      Tasks::Settings.create_defaults
      client = FluidClient.new
      mock_response = { "callback_registration" => { "id" => "reg-789" } }
      uuid = "reg-789"
      attributes = { timeout_in_seconds: 25, active: false }

      client.stub :put, mock_response do
        result = client.callback_registrations.update(uuid, attributes)

        _(result).must_equal mock_response
      end
    end

    it "deletes callback registration" do
      Tasks::Settings.create_defaults
      client = FluidClient.new
      mock_response = { "deleted" => true }
      uuid = "reg-123"

      client.stub :delete, mock_response do
        result = client.callback_registrations.delete(uuid)

        _(result).must_equal mock_response
      end
    end

    it "generates correct payload for create" do
      Tasks::Settings.create_defaults
      client = FluidClient.new
      attributes = {
        definition_name: "test_callback",
        url: "https://test.com/callback",
        timeout_in_seconds: 15,
        active: false,
      }

      expected_payload = {
        "callback_registration" => {
          "definition_name" => "test_callback",
          "url" => "https://test.com/callback",
          "timeout_in_seconds" => 15,
          "active" => false,
        },
      }

      _(client.callback_registrations.payload(attributes)).must_equal expected_payload
    end

    it "generates correct payload for update with uuid" do
      Tasks::Settings.create_defaults
      client = FluidClient.new
      attributes = { timeout_in_seconds: 25 }
      uuid = "reg-123"

      expected_payload = {
        "uuid" => "reg-123",
        "callback_registration" => {
          "definition_name" => nil,
          "url" => nil,
          "timeout_in_seconds" => 25,
          "active" => true,
        },
      }

      _(client.callback_registrations.payload(attributes, uuid)).must_equal expected_payload
    end

    it "builds query string correctly" do
      Tasks::Settings.create_defaults
      client = FluidClient.new
      params = { active: true, company_id: 123, page: 1, per_page: 50, sorted_by: "created_at" }

      expected_query = "?active=true&company_id=123&page=1&per_page=50&sorted_by=created_at"
      resource = client.callback_registrations

      _(resource.send(:build_query_string, params)).must_equal expected_query
    end
  end
end
