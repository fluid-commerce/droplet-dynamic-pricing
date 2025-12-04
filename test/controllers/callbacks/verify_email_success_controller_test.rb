require "test_helper"

class Callbacks::VerifyEmailSuccessControllerTest < ActionDispatch::IntegrationTest
  fixtures(:companies)

  def setup
    @company = companies(:acme)

    @cart_data = {
      "id" => 265327,
      "cart_token" => "ct_52blT6sVvSo4Ck2ygrKyW2",
      "email" => "test@example.com",
      "company" => {
        "id" => @company.fluid_company_id,
        "name" => @company.name,
        "subdomain" => "test",
      },
    }
  end

  test "handles verify_email_success callback successfully" do
    Callbacks::VerifyEmailSuccessService.stub(:call, { success: true }) do
      post "/callbacks/verify_email_success", params: {
        cart: @cart_data,
      }

      assert_response :success
      response_json = JSON.parse(response.body)
      assert_equal true, response_json["success"]
    end
  end

  test "handles service errors gracefully" do
    Callbacks::VerifyEmailSuccessService.stub(:call, ->(_params) { raise StandardError.new("Test error") }) do
      post "/callbacks/verify_email_success", params: {
        cart: @cart_data,
      }

      assert_response :internal_server_error
      response_json = JSON.parse(response.body)
      assert_equal false, response_json["success"]
      assert_equal "Test error", response_json["error"]
    end
  end

  test "returns bad request when service returns error" do
    Callbacks::VerifyEmailSuccessService.stub(:call, { success: false, error: "Service error" }) do
      post "/callbacks/verify_email_success", params: {
        cart: @cart_data,
      }

      assert_response :bad_request
      response_json = JSON.parse(response.body)
      assert_equal false, response_json["success"]
      assert_equal "Service error", response_json["error"]
    end
  end

  test "returns bad request when required params are missing in cart" do
    invalid_cart = @cart_data.except("email")

    post "/callbacks/verify_email_success", params: {
      cart: invalid_cart,
    }

    assert_response :bad_request
  end

  test "skips CSRF token verification" do
    Callbacks::VerifyEmailSuccessService.stub(:call, { success: true }) do
      post "/callbacks/verify_email_success", params: {
        cart: @cart_data,
      }

      assert_response :success
    end
  end
end
