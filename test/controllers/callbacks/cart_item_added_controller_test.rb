require "test_helper"

class Callbacks::CartItemAddedControllerTest < ActionDispatch::IntegrationTest
  fixtures(:companies)

  def company
    companies(:acme)
  end

  def cart_data
    {
      "id" => 265327,
      "cart_token" => "ct_52blT6sVvSo4Ck2ygrKyW2",
      "email" => "test@example.com",
      "metadata" => {
        "price_type" => "preferred_customer",
      },
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
        },
      ],
    }
  end

  def cart_item
    {
      "id" => 674138,
      "price" => "60.0",
      "subscription_price" => "54.0",
    }
  end

  test "handles cart_item_added callback successfully" do
    Callbacks::CartItemAddedService.stub(:call, { success: true }) do
      post "/callbacks/cart_item_added", params: {
        cart: cart_data,
        cart_item: cart_item,
      }

      assert_response :success
      response_json = JSON.parse(response.body)
      assert_equal true, response_json["success"]
    end
  end

  test "passes the batched cart_items through to the service" do
    seen_params = nil
    capture = lambda do |params|
      seen_params = params
      { success: true }
    end

    Callbacks::CartItemAddedService.stub(:call, capture) do
      post "/callbacks/cart_item_added", params: {
        cart: cart_data,
        cart_item: cart_item,
        cart_items: [ cart_item, { "id" => 674139, "price" => "40.0", "subscription_price" => "36.0" } ],
      }, as: :json

      assert_response :success
    end

    assert_equal [ 674138, 674139 ], seen_params[:cart_items].map { |item| item["id"] },
                 "the top-level cart_items array must survive strong params"
  end

  test "handles service errors gracefully" do
    Callbacks::CartItemAddedService.stub(:call, ->(_params) { raise StandardError.new("Test error") }) do
      post "/callbacks/cart_item_added", params: {
        cart: cart_data,
        cart_item: cart_item,
      }

      assert_response :internal_server_error
      response_json = JSON.parse(response.body)
      assert_equal false, response_json["success"]
      assert_equal "Test error", response_json["error"]
    end
  end

  test "returns bad request when service returns error" do
    Callbacks::CartItemAddedService.stub(:call, { success: false, error: "Service error" }) do
      post "/callbacks/cart_item_added", params: {
        cart: cart_data,
        cart_item: cart_item,
      }

      assert_response :bad_request
      response_json = JSON.parse(response.body)
      assert_equal false, response_json["success"]
      assert_equal "Service error", response_json["error"]
    end
  end

  test "skips CSRF token verification" do
    Callbacks::CartItemAddedService.stub(:call, { success: true }) do
      post "/callbacks/cart_item_added", params: {
        cart: cart_data,
        cart_item: cart_item,
      }

      assert_response :success
    end
  end

  test "requires cart_token in permitted_params" do
    invalid_params = {
      cart: cart_data.except("cart_token"),
      cart_item: cart_item,
    }

    post "/callbacks/cart_item_added", params: invalid_params

    assert_response :bad_request
  end

  test "allows request without email" do
    Callbacks::CartItemAddedService.stub(:call, { success: true }) do
      cart_without_email = cart_data.except("email")

      post "/callbacks/cart_item_added", params: {
        cart: cart_without_email,
        cart_item: cart_item,
      }

      assert_response :success
      response_json = JSON.parse(response.body)
      assert_equal true, response_json["success"]
    end
  end

  test "requires company_id in permitted_params" do
    invalid_cart_data = cart_data.dup
    invalid_cart_data["company"] = {}

    post "/callbacks/cart_item_added", params: {
      cart: invalid_cart_data,
      cart_item: cart_item,
    }

    assert_response :bad_request
  end

  test "requires cart_item in permitted_params" do
    post "/callbacks/cart_item_added", params: {
      cart: cart_data,
    }

    assert_response :bad_request
  end
end
