require "test_helper"

class Callbacks::CartEmailOnCreateControllerTest < ActionDispatch::IntegrationTest
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
    }
  end

  test "handles cart_email_on_create callback successfully" do
    Callbacks::CartEmailOnCreateService.stub(:call, { success: true }) do
      post "/callbacks/cart_email_on_create", params: { cart: cart_data }

      assert_response :success
      response_json = JSON.parse(response.body)
      assert_equal true, response_json["success"]
    end
  end

  test "handles service errors gracefully" do
    Callbacks::CartEmailOnCreateService.stub(:call, ->(_params) { raise StandardError.new("Test error") }) do
      post "/callbacks/cart_email_on_create", params: { cart: cart_data }

      assert_response :internal_server_error
      response_json = JSON.parse(response.body)
      assert_equal false, response_json["success"]
      assert_equal "Test error", response_json["error"]
    end
  end

  test "returns bad request when service returns error" do
    Callbacks::CartEmailOnCreateService.stub(:call, { success: false, error: "Service error" }) do
      post "/callbacks/cart_email_on_create", params: { cart: cart_data }

      assert_response :bad_request
      response_json = JSON.parse(response.body)
      assert_equal false, response_json["success"]
      assert_equal "Service error", response_json["error"]
    end
  end

  test "skips CSRF token verification" do
    Callbacks::CartEmailOnCreateService.stub(:call, { success: true }) do
      post "/callbacks/cart_email_on_create", params: { cart: cart_data }

      assert_response :success
    end
  end

  test "requires email in permitted_params" do
    invalid_cart_data = cart_data.dup
    invalid_cart_data.delete("email")

    post "/callbacks/cart_email_on_create", params: { cart: invalid_cart_data }

    assert_response :bad_request
  end

  test "requires company_id in permitted_params" do
    invalid_cart_data = cart_data.dup
    invalid_cart_data["company"] = {}

    post "/callbacks/cart_email_on_create", params: { cart: invalid_cart_data }

    assert_response :bad_request
  end
end
