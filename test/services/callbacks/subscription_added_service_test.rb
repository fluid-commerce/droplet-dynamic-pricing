require "test_helper"

class Callbacks::SubscriptionAddedServiceTest < ActiveSupport::TestCase
  fixtures(:companies)

  def company
    companies(:acme)
  end

  def cart_data
    {
      "id" => 265327,
      "cart_token" => "ct_52blT6sVvSo4Ck2ygrKyW2",
      "company" => {
        "id" => company.fluid_company_id,
        "name" => company.name,
        "subdomain" => "test",
      },
      "items" => [
        { "id" => 674137, "price" => "80.0", "subscription_price" => "72.0" },
        { "id" => 674138, "price" => "60.0", "subscription_price" => "54.0" },
      ],
    }
  end

  def callback_params
    { cart: cart_data }
  end

  test "call returns error when cart is blank" do
    service = Callbacks::SubscriptionAddedService.new({ cart: nil })
    result = service.call

    assert_equal({ success: false, message: "Cart is blank" }, result)
  end

  test "successfully updates cart metadata and item prices via fluid client" do
    mock_carts_resource = Minitest::Mock.new

    mock_carts_resource.expect :append_metadata, { "success" => true } do |token, metadata|
      token == cart_data["cart_token"] &&
      metadata.with_indifferent_access[:price_type] == "preferred_customer"
    end

    mock_carts_resource.expect :update_items_prices, { "success" => true } do |token, items|
      token_match = (token == cart_data["cart_token"])

      normalized_items = items.map(&:with_indifferent_access)
      item_1 = normalized_items.find { |i| i[:id].to_s == "674137" }
      item_2 = normalized_items.find { |i| i[:id].to_s == "674138" }

      prices_match = item_1 && item_1[:price].to_f == 72.0 &&
                     item_2 && item_2[:price].to_f == 54.0

      token_match && prices_match
    end

    mock_client = Object.new
    mock_client.define_singleton_method(:carts) { mock_carts_resource }

    service = Callbacks::SubscriptionAddedService.new(callback_params)

    service.stub(:find_company, company) do
      FluidClient.stub(:new, mock_client) do
        result = service.call
        assert result[:success]
      end
    end

    mock_carts_resource.verify
  end

  test "class method call works" do
    service_instance = Minitest::Mock.new
    service_instance.expect :call, { success: true }

    Callbacks::SubscriptionAddedService.stub(:new, ->(_params) { service_instance }) do
      result = Callbacks::SubscriptionAddedService.call(callback_params)
      assert_equal({ success: true }, result)
    end

    service_instance.verify
  end
end
