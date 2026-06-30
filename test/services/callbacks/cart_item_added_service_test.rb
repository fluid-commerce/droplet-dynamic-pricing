require "test_helper"

class Callbacks::CartItemAddedServiceTest < ActiveSupport::TestCase
  include VolumeTestHelpers

  fixtures(:companies)

  def setup
    @company = companies(:acme)
    @cart_data = {
      "id" => 265327,
      "cart_token" => "ct_52blT6sVvSo4Ck2ygrKyW2",
      "customer_id" => 12345,
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

  # Turns on the per-company toggle so dynamic pricing yields to yoli-promos
  # wholesale on enrollment carts. Persisted because the service re-resolves
  # the company from the DB via find_company.
  def enable_yield_to_enrollment_wholesale!
    @company.create_integration_setting!(
      settings: { "yield_to_enrollment_wholesale" => true }
    )
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

  test "call skips enrollment cart (type=enrollment) when company yields to wholesale" do
    enable_yield_to_enrollment_wholesale!
    enrollment_cart = @cart_data.dup
    enrollment_cart["type"] = "enrollment"
    raising_client = Object.new
    raising_client.define_singleton_method(:carts) { raise "must not reprice an enrollment cart" }

    service = Callbacks::CartItemAddedService.new({ cart: enrollment_cart, cart_item: @cart_item })
    service.define_singleton_method(:fluid_client) { raising_client }

    result = service.call
    assert_equal({ success: true }, result)
  end

  test "call skips enrollment-pack item when company yields to wholesale" do
    enable_yield_to_enrollment_wholesale!
    cart = @cart_data.dup
    cart["type"] = "regular"
    cart["items"] = [ { "id" => 1, "price" => "80.0", "enrollment_pack_id" => 580 } ]
    raising_client = Object.new
    raising_client.define_singleton_method(:carts) { raise "must not reprice an enrollment cart" }

    service = Callbacks::CartItemAddedService.new({ cart: cart, cart_item: @cart_item })
    service.define_singleton_method(:fluid_client) { raising_client }

    result = service.call
    assert_equal({ success: true }, result)
  end

  test "call does NOT skip enrollment cart when company does not yield to wholesale" do
    # No integration_setting / toggle off → dynamic pricing must still run so
    # the company keeps preferred-customer pricing on its enrollment carts.
    enrollment_cart = @cart_data.dup
    enrollment_cart["type"] = "enrollment"

    repriced = false
    carts_api = Object.new
    carts_api.define_singleton_method(:update_items_prices) { |*_| repriced = true }
    carts_api.define_singleton_method(:append_metadata) { |*_| nil }
    repricing_client = Object.new
    repricing_client.define_singleton_method(:carts) { carts_api }

    service = Callbacks::CartItemAddedService.new({ cart: enrollment_cart, cart_item: @cart_item })
    service.define_singleton_method(:fluid_client) { repricing_client }

    service.call
    assert repriced, "expected dynamic pricing to reprice the enrollment cart when the toggle is off"
  end

  test "call returns success without updates when no preferred_customer and no subscription in cart" do
    cart_without_preferred = @cart_data.dup
    cart_without_preferred["metadata"] = { "price_type" => "regular_customer" }
    cart_without_preferred["items"] = [
      { "id" => 674137, "price" => "80.0", "subscription" => false },
    ]

    service = Callbacks::CartItemAddedService.new({
      cart: cart_without_preferred,
      cart_item: @cart_item,
    })
    result = service.call

    assert_equal true, result[:success]
    assert_equal "Cart does not have preferred_customer pricing", result[:message]
  end

  test "call returns success without updates when no metadata and no subscription in cart" do
    cart_without_price_type = @cart_data.dup
    cart_without_price_type["metadata"] = {}
    cart_without_price_type["items"] = []

    service = Callbacks::CartItemAddedService.new({
      cart: cart_without_price_type,
      cart_item: @cart_item,
    })
    result = service.call

    assert_equal true, result[:success]
    assert_equal "Cart does not have preferred_customer pricing", result[:message]
  end

  test "call updates when cart has subscription item even without preferred_customer metadata" do
    cart_with_subscription = @cart_data.dup
    cart_with_subscription["metadata"] = {}
    cart_with_subscription["items"] = [
      { "id" => 674137, "price" => "72.0", "subscription" => true },
    ]

    fake_carts = FakeCartsResource.new
    mock_client = Object.new
    mock_client.define_singleton_method(:carts) { fake_carts }

    service = Callbacks::CartItemAddedService.new({
      cart: cart_with_subscription,
      cart_item: @cart_item,
    })
    service.define_singleton_method(:fluid_client) { mock_client }

    result = service.call

    assert_equal true, result[:success]
    assert_equal "Cart item updated to subscription price successfully", result[:message]
    assert_equal 1, fake_carts.metadata_calls.size
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

    call = fake_carts.items_prices_calls.first
    assert_equal @cart_data["cart_token"], call[:token]
    expected_item_data = [ {
      "id" => @cart_item["id"],
      "price" => @cart_item["subscription_price"],
    } ]
    assert_equal expected_item_data, call[:items]
  end

  test "updates cart items prices with regular price when subscription_price is not available" do
    cart_item_without_subscription_price = {
      "id" => 674140,
      "price" => "50.0",
    }

    fake_carts = FakeCartsResource.new
    mock_client = Object.new
    mock_client.define_singleton_method(:carts) { fake_carts }

    service = Callbacks::CartItemAddedService.new({
      cart: @cart_data,
      cart_item: cart_item_without_subscription_price,
    })
    service.define_singleton_method(:fluid_client) { mock_client }

    service.call

    call = fake_carts.items_prices_calls.first
    assert_equal @cart_data["cart_token"], call[:token]
    expected_item_data = [ {
      "id" => cart_item_without_subscription_price["id"],
      "price" => cart_item_without_subscription_price["price"],
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

  test "applies subscription volume for the added item when company opts in" do
    @company.create_integration_setting!(settings: { "adjust_volumes_for_subscription" => true })
    cart = @cart_data.dup
    cart["country_code"] = "US"
    cart_item = {
      "id" => 674139, "variant_id" => 10, "price" => "100.0",
      "subscription_price" => "90.0", "quantity" => 1,
    }

    carts = VolumeTestHelpers::FakeCarts.new
    variants = VolumeTestHelpers::FakeVariants.new(10 => [ { "country_code" => "US", "cv" => 100, "qv" => 50,
"price" => "100.0", "subscription_price" => "90.0", } ])
    client = build_volume_client(carts: carts, variants: variants)

    service = Callbacks::CartItemAddedService.new({ cart: cart, cart_item: cart_item })
    service.define_singleton_method(:fluid_client) { client }

    service.call

    assert_equal 1, carts.volume_calls.size
    # ratio = (100-90)/100 = 0.1 -> 100*0.9 = 90, 50*0.9 = 45
    assert_equal 674139, carts.volume_calls.first[:item_id]
    assert_equal({ "cv" => 90, "qv" => 45 }, carts.volume_calls.first[:volumes])
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
