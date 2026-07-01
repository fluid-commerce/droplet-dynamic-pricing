require "test_helper"

class Callbacks::CartCustomerDetachedControllerTest < ActionDispatch::IntegrationTest
  fixtures(:companies)

  def company
    companies(:acme)
  end

  def cart_data
    {
      "cart_token" => "ct_det",
      "metadata" => { "price_type" => "preferred_customer" },
      "company" => { "id" => company.fluid_company_id, "name" => company.name },
      "items" => [],
    }
  end

  def params
    {
      cart: cart_data,
      context: {
        "trigger_source" => "logout", "company_id" => company.fluid_company_id, "previous_customer_id" => 888,
      },
    }
  end

  test "dispatches cart_customer_detached to the service" do
    Callbacks::CartCustomerDetachedService.stub(:call, { success: true }) do
      post "/callbacks/cart_customer_detached", params: params

      assert_response :success
      assert_equal true, JSON.parse(response.body)["success"]
    end
  end

  test "requires cart_token" do
    post "/callbacks/cart_customer_detached", params: params.merge(cart: cart_data.except("cart_token"))
    assert_response :bad_request
  end

  test "requires company id" do
    bad = cart_data.dup
    bad["company"] = {}
    post "/callbacks/cart_customer_detached", params: params.merge(cart: bad)
    assert_response :bad_request
  end
end
