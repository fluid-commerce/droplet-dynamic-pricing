require "test_helper"

class Callbacks::CartCustomerAttachedControllerTest < ActionDispatch::IntegrationTest
  fixtures(:companies)

  def company
    companies(:acme)
  end

  def cart_data
    {
      "cart_token" => "ct_att",
      "email" => "vip@example.com",
      "customer_id" => 888,
      "metadata" => { "price_type" => nil },
      "company" => { "id" => company.fluid_company_id, "name" => company.name },
      "items" => [],
    }
  end

  def params
    {
      cart: cart_data,
      customer: { "id" => 888, "email" => "vip@example.com" },
      context: { "trigger_source" => "session_inherited", "company_id" => company.fluid_company_id },
    }
  end

  test "dispatches cart_customer_attached to the service" do
    Callbacks::CartCustomerAttachedService.stub(:call, { success: true }) do
      post "/callbacks/cart_customer_attached", params: params

      assert_response :success
      assert_equal true, JSON.parse(response.body)["success"]
    end
  end

  test "requires cart_token" do
    post "/callbacks/cart_customer_attached", params: params.merge(cart: cart_data.except("cart_token"))
    assert_response :bad_request
  end

  test "requires company id" do
    bad = cart_data.dup
    bad["company"] = {}
    post "/callbacks/cart_customer_attached", params: params.merge(cart: bad)
    assert_response :bad_request
  end
end
