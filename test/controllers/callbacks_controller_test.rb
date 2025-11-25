require "test_helper"

describe CallbacksController do
  fixtures(:companies)

  let(:company) { companies(:acme) }
  let(:cart_data) do
    {
      "id" => 265327,
      "cart_token" => "ct_52blT6sVvSo4Ck2ygrKyW2",
      "company" => {
        "id" => company.fluid_company_id,
        "name" => company.name,
        "subdomain" => "test",
      },
      "items" => [
        {
          "id" => 674137,
          "price" => "80.0",
          "subscription_price" => "72.0",
          "product" => {
            "price" => "80.0",
          },
        },
      ],
    }
  end

  describe "POST #create" do
    describe "subscription_added callback" do
      it "delegates to SubscriptionCallbackService and returns success" do
        service_mock = Minitest::Mock.new
        service_mock.expect(:handle_subscription_added, { success: true })

        SubscriptionCallbackService.stub(:new, service_mock) do
          post callback_url("subscription_added"), params: { cart: cart_data }

          assert_response :success
          response_json = JSON.parse(response.body)
          assert_equal true, response_json["success"]
        end

        service_mock.verify
      end

      it "returns service result when service returns error" do
        service_mock = Minitest::Mock.new
        service_mock.expect(:handle_subscription_added, { success: false, error: "Service error" })

        SubscriptionCallbackService.stub(:new, service_mock) do
          post callback_url("subscription_added"), params: { cart: cart_data }

          assert_response :bad_request
          response_json = JSON.parse(response.body)
          assert_equal false, response_json["success"]
          assert_equal "Service error", response_json["error"]
        end

        service_mock.verify
      end
    end

    describe "subscription_removed callback" do
      it "delegates to SubscriptionCallbackService and returns success" do
        service_mock = Minitest::Mock.new
        service_mock.expect(:handle_subscription_removed, { success: true })

        SubscriptionCallbackService.stub(:new, service_mock) do
          post callback_url("subscription_removed"), params: { cart: cart_data }

          assert_response :success
          response_json = JSON.parse(response.body)
          assert_equal true, response_json["success"]
        end

        service_mock.verify
      end
    end

    describe "unknown callback" do
      it "returns bad request for unknown callback type" do
        post callback_url("unknown_callback"), params: { cart: cart_data }

        assert_response :bad_request
        response_json = JSON.parse(response.body)
        assert_equal false, response_json["success"]
        assert_includes response_json["error"], "Unknown callback: unknown_callback"
      end
    end

    describe "exception handling" do
      it "handles service exceptions and returns internal server error" do
        SubscriptionCallbackService.stub(:new, ->(params) { raise StandardError.new("Unexpected error") }) do
          post callback_url("subscription_added"), params: { cart: cart_data }

          assert_response :internal_server_error
          response_json = JSON.parse(response.body)
          assert_equal false, response_json["success"]
          assert_equal "Unexpected error", response_json["error"]
        end
      end
    end

    describe "parameter handling" do
      it "passes correct callback_params to service" do
        service_instance = nil
        service_mock = Minitest::Mock.new
        service_mock.expect(:handle_subscription_added, { success: true })

        SubscriptionCallbackService.stub(:new, ->(params) {
          service_instance = params
          service_mock
        }) do
          post callback_url("subscription_added"), params: { cart: cart_data }

          # Verify the service received the correct parameters
          assert_equal cart_data["cart_token"], service_instance[:cart]["cart_token"]
          assert_equal cart_data["company"]["id"].to_s, service_instance[:cart]["company"]["id"].to_s
        end

        service_mock.verify
      end
    end

    describe "CSRF protection" do
      it "skips CSRF token verification" do
        # This test ensures that external callbacks can work without CSRF tokens
        service_mock = Minitest::Mock.new
        service_mock.expect(:handle_subscription_added, { success: true })

        SubscriptionCallbackService.stub(:new, ->(params) { service_mock }) do
          # Make request without CSRF token
          post callback_url("subscription_added"), params: { cart: cart_data }

          assert_response :success
        end

        service_mock.verify
      end
    end
  end
end
