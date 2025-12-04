require "test_helper"

class Callbacks::SubscriptionRemovedControllerTest < ActionDispatch::IntegrationTest
  fixtures(:companies)

  def company
    companies(:acme)
  end

  def cart_data
    {
      "id" => 265327,
      "cart_token" => "ct_52blT6sVvSo4Ck2ygrKyW2",
      "email" => "test@example.com",
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

  def test_handles_subscription_removed_callback_successfully
    Callbacks::SubscriptionRemovedService.stub(:call, { success: true }) do
      post "/callbacks/subscription_removed", params: { cart: cart_data }

      assert_response :success
      response_json = JSON.parse(response.body)
      assert_equal true, response_json["success"]
    end
  end

  def test_handles_service_errors_gracefully
    Callbacks::SubscriptionRemovedService.stub(:call, ->(_params) { raise StandardError.new("Test error") }) do
      post "/callbacks/subscription_removed", params: { cart: cart_data }

      assert_response :internal_server_error
      response_json = JSON.parse(response.body)
      assert_equal false, response_json["success"]
      assert_equal "Test error", response_json["error"]
    end
  end

  def test_returns_bad_request_when_service_returns_error
    Callbacks::SubscriptionRemovedService.stub(:call, { success: false, error: "Service error" }) do
      post "/callbacks/subscription_removed", params: { cart: cart_data }

      assert_response :bad_request
      response_json = JSON.parse(response.body)
      assert_equal false, response_json["success"]
      assert_equal "Service error", response_json["error"]
    end
  end

  def test_skips_csrf_token_verification
    Callbacks::SubscriptionRemovedService.stub(:call, { success: true }) do
      post "/callbacks/subscription_removed", params: { cart: cart_data }

      assert_response :success
    end
  end

  def test_requires_cart_token_in_permitted_params
    invalid_params = { cart: cart_data.except("cart_token") }

    post "/callbacks/subscription_removed", params: invalid_params

    assert_response :bad_request
  end

  def test_requires_email_in_permitted_params
    invalid_params = { cart: cart_data.except("email") }

    post "/callbacks/subscription_removed", params: invalid_params

    assert_response :bad_request
  end

  def test_requires_company_id_in_permitted_params
    invalid_cart_data = cart_data.dup
    invalid_cart_data["company"] = {}

    post "/callbacks/subscription_removed", params: { cart: invalid_cart_data }

    assert_response :bad_request
  end
end
