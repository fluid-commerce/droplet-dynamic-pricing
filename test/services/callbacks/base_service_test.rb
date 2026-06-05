require "test_helper"

class Callbacks::BaseServiceTest < ActiveSupport::TestCase
  fixtures(:companies)

  def setup
    @company = companies(:acme)
    @cart_data = {
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
          "product" => {
            "price" => "80.0",
          },
        },
      ],
    }
    @callback_params = { cart: @cart_data }
  end

  test "class method call creates instance and calls call method" do
    # Create a test service class
    test_service_class = Class.new(Callbacks::BaseService) do
      def call
        { success: true, test: "worked" }
      end
    end

    result = test_service_class.call(@callback_params)

    assert_equal({ success: true, test: "worked" }, result)
  end

  test "call method raises NotImplementedError in base class" do
    service = Callbacks::BaseService.new(@callback_params)

    assert_raises(NotImplementedError) do
      service.call
    end
  end

  test "initializes with callback_params" do
    service = Callbacks::BaseService.new(@callback_params)
    assert_equal @callback_params, service.instance_variable_get(:@callback_params)
  end

  test "cart_items_with_regular_price falls back to item.price when product.price is zero (bundle case)" do
    bundle_cart = @cart_data.deep_dup
    bundle_cart["items"] = [{
      "id" => 1,
      "price" => "333.0",
      "subscription_price" => "300.0",
      "product" => { "price" => "0.0" },
    }]
    service = Callbacks::BaseService.new(cart: bundle_cart)

    result = service.send(:cart_items_with_regular_price)

    assert_equal "333.0", result.first["price"]
  end

  test "cart_items_with_subscription_price falls back to item.price when subscription_price is zero" do
    bundle_cart = @cart_data.deep_dup
    bundle_cart["items"] = [{
      "id" => 1,
      "price" => "333.0",
      "subscription_price" => "0.0",
      "product" => { "price" => "333.0" },
    }]
    service = Callbacks::BaseService.new(cart: bundle_cart)

    result = service.send(:cart_items_with_subscription_price)

    assert_equal "333.0", result.first["price"]
  end

  test "update_cart_items_prices drops items priced at zero to prevent $0 checkouts" do
    service = Callbacks::BaseService.new(@callback_params)
    items = [
      { "id" => 1, "price" => "100.0" },
      { "id" => 2, "price" => "0.0" },
      { "id" => 3, "price" => 0 },
    ]
    captured = nil
    mock_carts = Object.new
    mock_carts.define_singleton_method(:update_items_prices) { |_token, data| captured = data }
    mock_client = Object.new
    mock_client.define_singleton_method(:carts) { mock_carts }
    service.define_singleton_method(:fluid_client) { mock_client }
    service.define_singleton_method(:cart_token) { "test-token" }

    service.send(:update_cart_items_prices, items)

    assert_equal [{ "id" => 1, "price" => "100.0" }], captured
  end

  test "update_cart_items_prices skips API call entirely when all items are zero-priced" do
    service = Callbacks::BaseService.new(@callback_params)
    items = [{ "id" => 1, "price" => "0.0" }, { "id" => 2, "price" => 0 }]
    called = false
    mock_carts = Object.new
    mock_carts.define_singleton_method(:update_items_prices) { |_token, _data| called = true }
    mock_client = Object.new
    mock_client.define_singleton_method(:carts) { mock_carts }
    service.define_singleton_method(:fluid_client) { mock_client }
    service.define_singleton_method(:cart_token) { "test-token" }

    service.send(:update_cart_items_prices, items)

    refute called, "update_items_prices should not be called when all prices are zero"
  end
end
