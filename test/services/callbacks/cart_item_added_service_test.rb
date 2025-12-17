require "test_helper"

class Callbacks::CartItemAddedServiceTest < ActiveSupport::TestCase
  fixtures(:companies)

  def setup
    @company = companies(:acme)
    @cart_data = {
      "id" => 265327,
      "cart_token" => "ct_52blT6sVvSo4Ck2ygrKyW2",
      "metadata" => {
        "price_type" => Callbacks::BaseService::PREFERRED_CUSTOMER_TYPE,
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
        {
          "id" => 674138,
          "price" => "60.0",
          "subscription_price" => "54.0",
        },
      ],
    }
    @cart_item = {
      "id" => 674139,
      "price" => "100.0",
      "subscription_price" => "90.0",
    }
    @callback_params = {
      cart: @cart_data,
      cart_item: @cart_item,
    }
  end

  test "call returns failure when cart is blank" do
    service = Callbacks::CartItemAddedService.new({ cart: nil, cart_item: @cart_item })
    result = service.call

    assert_equal false, result[:success]
    assert_equal "Cart is blank", result[:message]
  end

  test "call returns failure when cart_item is blank" do
    service = Callbacks::CartItemAddedService.new({ cart: @cart_data, cart_item: nil })
    result = service.call

    assert_equal false, result[:success]
    assert_equal "Cart item is blank", result[:message]
  end

  test "call returns success when price_type is not preferred_customer and item has no subscription" do
    cart_without_preferred = @cart_data.dup
    cart_without_preferred["metadata"] = { "price_type" => "regular_customer" }

    service = Callbacks::CartItemAddedService.new({
      cart: cart_without_preferred,
      cart_item: @cart_item,
    })
    result = service.call

    assert_equal true, result[:success]
    assert_equal "Cart does not have preferred_customer pricing", result[:message]
  end

  test "call returns success when price_type is not set and item has no subscription" do
    cart_without_price_type = @cart_data.dup
    cart_without_price_type["metadata"] = {}

    service = Callbacks::CartItemAddedService.new({
      cart: cart_without_price_type,
      cart_item: @cart_item,
    })
    result = service.call

    assert_equal true, result[:success]
    assert_equal "Cart does not have preferred_customer pricing", result[:message]
  end

  test "call updates metadata and all items when item has subscription and cart has no preferred_customer" do
    cart_without_preferred = @cart_data.dup
    cart_without_preferred["metadata"] = {}
    cart_item_with_subscription = @cart_item.merge("subscription" => true)

    fake_carts = FakeCartsResource.new
    mock_client = Object.new
    mock_client.define_singleton_method(:carts) { fake_carts }

    service = Callbacks::CartItemAddedService.new({
      cart: cart_without_preferred,
      cart_item: cart_item_with_subscription,
    })
    service.define_singleton_method(:fluid_client) { mock_client }

    result = service.call

    assert_equal true, result[:success]
    assert_equal "Cart updated to preferred_customer pricing due to subscription item", result[:message]
    assert_equal 1, fake_carts.metadata_calls.size
    assert_equal({ "price_type" => "preferred_customer" }, fake_carts.metadata_calls.first[:metadata])
    assert_equal 1, fake_carts.items_prices_calls.size
  end

  test "call processes cart_item_added successfully when price_type is preferred_customer" do
    fake_carts = FakeCartsResource.new
    mock_client = Object.new
    mock_client.define_singleton_method(:carts) { fake_carts }

    service = Callbacks::CartItemAddedService.new(@callback_params)
    service.define_singleton_method(:fluid_client) { mock_client }

    result = service.call

    assert_equal true, result[:success]
    assert_includes result[:message], "Cart item updated to subscription price successfully"
    assert_equal 1, fake_carts.items_prices_calls.size
  end

  test "updates cart items prices with subscription_price when available" do
    fake_carts = FakeCartsResource.new
    mock_client = Object.new
    mock_client.define_singleton_method(:carts) { fake_carts }

    service = Callbacks::CartItemAddedService.new(@callback_params)
    service.define_singleton_method(:fluid_client) { mock_client }

    service.call

    assert_equal 1, fake_carts.items_prices_calls.size
    call = fake_carts.items_prices_calls.first
    assert_equal @cart_data["cart_token"], call[:token]
    expected_item_data = [ {
      "id" => @cart_item["id"],
      "price" => @cart_item["subscription_price"],
    } ]
    assert_equal expected_item_data, call[:items]
  end

  test "updates cart items prices with regular price when subscription_price is not available" do
    cart_item_without_subscription = {
      "id" => 674140,
      "price" => "50.0",
    }

    fake_carts = FakeCartsResource.new
    mock_client = Object.new
    mock_client.define_singleton_method(:carts) { fake_carts }

    service = Callbacks::CartItemAddedService.new({
      cart: @cart_data,
      cart_item: cart_item_without_subscription,
    })
    service.define_singleton_method(:fluid_client) { mock_client }

    service.call

    assert_equal 1, fake_carts.items_prices_calls.size
    call = fake_carts.items_prices_calls.first
    assert_equal @cart_data["cart_token"], call[:token]
    expected_item_data = [ {
      "id" => cart_item_without_subscription["id"],
      "price" => cart_item_without_subscription["price"],
    } ]
    assert_equal expected_item_data, call[:items]
  end

  test "returns error if item ID is missing during price update" do
    cart_item_no_id = @cart_item.dup
    cart_item_no_id.delete("id")

    service = Callbacks::CartItemAddedService.new({
      cart: @cart_data,
      cart_item: cart_item_no_id,
    })

    result = service.call
    assert_equal false, result[:success]
    assert_equal "Item ID is required", result[:message]
  end

  test "returns error if item has no price during price update" do
    cart_item_no_price = @cart_item.dup
    cart_item_no_price.delete("price")
    cart_item_no_price.delete("subscription_price")

    service = Callbacks::CartItemAddedService.new({
      cart: @cart_data,
      cart_item: cart_item_no_price,
    })

    result = service.call
    assert_equal false, result[:success]
    assert_equal "Item price is not present in cart item", result[:message]
  end

  test "class method call works" do
    service_instance = Minitest::Mock.new
    service_instance.expect(:call, { success: true })

    Callbacks::CartItemAddedService.stub(:new, ->(params) { service_instance }) do
      result = Callbacks::CartItemAddedService.call(@callback_params)

      assert_equal({ success: true }, result)
    end

    service_instance.verify
  end

  test "handles StandardError gracefully" do
    service = Callbacks::CartItemAddedService.new(@callback_params)

    service.stub(:update_item_to_subscription_price, -> { raise StandardError.new("Network error") }) do
      result = service.call

      assert_equal false, result[:success]
      assert_equal "unexpected_error", result[:error]
      assert_equal "An unexpected error occurred", result[:message]
    end
  end
end

class FakeCartsResource
  attr_reader :items_prices_calls, :metadata_calls

  def initialize
    @items_prices_calls = []
    @metadata_calls = []
  end

  def update_items_prices(token, items)
    @items_prices_calls << { token: token, items: items }
    { "success" => true }
  end

  def append_metadata(token, metadata)
    @metadata_calls << { token: token, metadata: metadata }
    { "success" => true }
  end
end
