# frozen_string_literal: true

require "test_helper"

class Callbacks::CartItemUpdatedControllerTest < ActionDispatch::IntegrationTest
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

  test "handles cart_item_updated callback successfully" do
    Callbacks::CartItemUpdatedService.stub(:call, { success: true }) do
      post "/callbacks/cart_item_updated", params: {
        cart: cart_data,
        cart_item: cart_item,
      }

      assert_response :success
      response_json = JSON.parse(response.body)
      assert_equal true, response_json["success"]
    end
  end

  test "handles service errors gracefully" do
    Callbacks::CartItemUpdatedService.stub(:call, ->(_params) { raise StandardError.new("Test error") }) do
      post "/callbacks/cart_item_updated", params: {
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
    Callbacks::CartItemUpdatedService.stub(:call, { success: false, error: "Service error" }) do
      post "/callbacks/cart_item_updated", params: {
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
    Callbacks::CartItemUpdatedService.stub(:call, { success: true }) do
      post "/callbacks/cart_item_updated", params: {
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

    post "/callbacks/cart_item_updated", params: invalid_params

    assert_response :bad_request
  end

  test "allows request with context" do
    Callbacks::CartItemUpdatedService.stub(:call, { success: true }) do
      post "/callbacks/cart_item_updated", params: {
        cart: cart_data,
        cart_item: cart_item,
        context: {
          "previous_quantity" => 1,
          "new_quantity" => 2,
          "quantity_delta" => 1,
        },
      }

      assert_response :success
      response_json = JSON.parse(response.body)
      assert_equal true, response_json["success"]
    end
  end

  test "requires company_id in permitted_params" do
    invalid_cart_data = cart_data.dup
    invalid_cart_data["company"] = {}

    post "/callbacks/cart_item_updated", params: {
      cart: invalid_cart_data,
      cart_item: cart_item,
    }

    assert_response :bad_request
  end

  test "requires cart_item in permitted_params" do
    post "/callbacks/cart_item_updated", params: {
      cart: cart_data,
    }

    assert_response :bad_request
  end
end
