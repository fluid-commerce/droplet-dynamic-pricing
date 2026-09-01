require "test_helper"

describe Fluid::Members do
  before do
    Tasks::Settings.create_defaults
  end

  describe "Resource" do
    it "returns a resource" do
      client = FluidClient.new

      _(client.members).must_be_instance_of Fluid::Members::Resource
    end

    it "memoizes the resource" do
      client = FluidClient.new

      _(client.members).must_be_same_as client.members
    end
  end

  describe "#find" do
    it "gets a member by id" do
      client = FluidClient.new
      member_id = 4321
      mock_response = {
        "member" => {
          "id" => member_id,
          "member_type_slug" => "preferred_customer",
          "member_type" => { "id" => 7, "name" => "Preferred Customer", "slug" => "preferred_customer" },
        },
      }

      client.stub :get, ->(path, _options = {}) do
        _(path).must_equal "/api/v2025-06/members/#{member_id}"
        mock_response
      end do
        _(client.members.find(member_id)).must_equal mock_response
      end
    end

    # The 404 belongs to the caller: resolving customer -> member is expected to
    # miss, and swallowing it here would hand back a nil the caller reads as
    # "member with no type".
    it "lets a 404 reach the caller" do
      client = FluidClient.new
      raiser = ->(_path, _options = {}) { raise FluidClient::ResourceNotFoundError, "Resource not found: 404" }

      client.stub :get, raiser do
        _(-> { client.members.find(99) }).must_raise FluidClient::ResourceNotFoundError
      end
    end
  end

  describe "#find_by" do
    it "resolves a member by external id" do
      client = FluidClient.new
      mock_response = { "member" => { "id" => 4321, "member_type_slug" => "preferred_customer" } }

      client.stub :get, ->(path, _options = {}) do
        _(path).must_equal "/api/v2025-06/members/find?external_id=cust-123"
        mock_response
      end do
        _(client.members.find_by(external_id: "cust-123")).must_equal mock_response
      end
    end

    it "resolves a member by email" do
      client = FluidClient.new

      client.stub :get, ->(path, _options = {}) do
        _(path).must_equal "/api/v2025-06/members/find?email=one%40example.com"
        {}
      end do
        client.members.find_by(email: "one@example.com")
      end
    end

    it "escapes values that are not URL safe" do
      client = FluidClient.new

      client.stub :get, ->(path, _options = {}) do
        _(path).must_equal "/api/v2025-06/members/find?email=a%2Bb%40example.com"
        {}
      end do
        client.members.find_by(email: "a+b@example.com")
      end
    end

    # Fluid answers `find` with 422 when no identifier is given, so spending a
    # round trip to learn that is pure latency on a callback's budget.
    it "refuses to call out with no identifier" do
      client = FluidClient.new

      error = _(-> { client.members.find_by }).must_raise ArgumentError
      _(error.message).must_match(/email/)
    end

    # Fluid does not AND the identifiers: it matches on the FIRST present one in
    # a fixed order (email, username, external_id, legacy_customer_id), so
    # find_by(external_id:, email:) silently ignores the external_id and can
    # return a different member than the caller meant.
    it "refuses more than one identifier" do
      client = FluidClient.new

      _(-> { client.members.find_by(external_id: "cust-123", email: "one@example.com") })
        .must_raise ArgumentError
    end

    it "refuses an identifier Fluid does not match on" do
      client = FluidClient.new

      _(-> { client.members.find_by(customer_id: 7) }).must_raise ArgumentError
    end

    it "accepts every identifier Fluid matches on" do
      client = FluidClient.new
      paths = []

      client.stub :get, ->(path, _options = {}) { paths << path; {} } do
        client.members.find_by(email: "one@example.com")
        client.members.find_by(username: "jdoe")
        client.members.find_by(external_id: "cust-123")
        client.members.find_by(legacy_customer_id: 99)
      end

      _(paths).must_equal [
        "/api/v2025-06/members/find?email=one%40example.com",
        "/api/v2025-06/members/find?username=jdoe",
        "/api/v2025-06/members/find?external_id=cust-123",
        "/api/v2025-06/members/find?legacy_customer_id=99",
      ]
    end

    it "lets a 404 reach the caller" do
      client = FluidClient.new
      raiser = ->(_path, _options = {}) { raise FluidClient::ResourceNotFoundError, "Resource not found: 404" }

      client.stub :get, raiser do
        _(-> { client.members.find_by(email: "nobody@example.com") }).must_raise FluidClient::ResourceNotFoundError
      end
    end
  end

  describe "#update_member_type" do
    it "puts the new slug on the member" do
      client = FluidClient.new
      member_id = 4321
      mock_response = { "member" => { "id" => member_id, "member_type_slug" => "retail" } }

      client.stub :put, ->(path, options = {}) do
        _(path).must_equal "/api/v2025-06/members/#{member_id}/member-type"
        _(options).must_equal({ body: { "member_type_slug" => "retail" } })
        mock_response
      end do
        _(client.members.update_member_type(member_id, "retail")).must_equal mock_response
      end
    end

    it "sends the slug as a string" do
      client = FluidClient.new

      client.stub :put, ->(_path, options = {}) do
        _(options.dig(:body, "member_type_slug")).must_equal "preferred_customer"
        {}
      end do
        client.members.update_member_type(1, :preferred_customer)
      end
    end
  end
end
