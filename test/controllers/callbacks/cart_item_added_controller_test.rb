require "test_helper"

class Callbacks::CartItemAddedControllerTest < ActionDispatch::IntegrationTest
  fixtures(:companies)

  def setup
    @company = companies(:acme)
    @cart_data = {
      "id" => 265327,
      "cart_token" => "ct_52blT6sVvSo4Ck2ygrKyW2",
      "metadata" => {
        "price_type" => "preferred_customer",
      },
      "company" => {
        "id" => @company.fluid_company_id,
        "name" => @company.name,
        "subdomain" => "test",
      },
      "items" => [
        {
          "id" => 674137,
          "price" => "80.0",
          "subscription_price" => "72.0",
        },
      ],
    }
    @cart_item = {
      "id" => 674138,
      "price" => "60.0",
      "subscription_price" => "54.0",
    }
  end

  test "handles cart_item_added callback successfully" do
    Callbacks::CartItemAddedService.stub(:call, { success: true }) do
      post "/callback/cart_item_added", params: {
        cart: @cart_data,
        cart_item: @cart_item,
      }

      assert_response :success
      response_json = JSON.parse(response.body)
      assert_equal true, response_json["success"]
    end
  end

  test "handles service errors gracefully" do
    Callbacks::CartItemAddedService.stub(:call, ->(params) { raise StandardError.new("Test error") }) do
      post "/callback/cart_item_added", params: {
        cart: @cart_data,
        cart_item: @cart_item,
      }

      assert_response :internal_server_error
      response_json = JSON.parse(response.body)
      assert_equal false, response_json["success"]
      assert_equal "Test error", response_json["error"]
    end
  end

  test "returns bad request when service returns error" do
    Callbacks::CartItemAddedService.stub(:call, { success: false, error: "Service error" }) do
      post "/callback/cart_item_added", params: {
        cart: @cart_data,
        cart_item: @cart_item,
      }

      assert_response :bad_request
      response_json = JSON.parse(response.body)
      assert_equal false, response_json["success"]
      assert_equal "Service error", response_json["error"]
    end
  end

  test "skips CSRF token verification" do
    Callbacks::CartItemAddedService.stub(:call, { success: true }) do
      post "/callback/cart_item_added", params: {
        cart: @cart_data,
        cart_item: @cart_item,
      }

      assert_response :success
    end
  end
end
