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
    bundle_cart["items"] = [ {
      "id" => 1,
      "price" => "333.0",
      "subscription_price" => "300.0",
      "product" => { "price" => "0.0" },
    } ]
    service = Callbacks::BaseService.new(cart: bundle_cart)

    result = service.send(:cart_items_with_regular_price)

    assert_equal "333.0", result.first["price"]
  end

  test "cart_items_with_subscription_price falls back to item.price when subscription_price is zero" do
    bundle_cart = @cart_data.deep_dup
    bundle_cart["items"] = [ {
      "id" => 1,
      "price" => "333.0",
      "subscription_price" => "0.0",
      "product" => { "price" => "333.0" },
    } ]
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

    assert_equal [ { "id" => 1, "price" => "100.0" } ], captured
  end

  test "update_cart_items_prices skips API call entirely when all items are zero-priced" do
    service = Callbacks::BaseService.new(@callback_params)
    items = [ { "id" => 1, "price" => "0.0" }, { "id" => 2, "price" => 0 } ]
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

  # --- Volume adjustment (STU2-2526) ---

  def enable_volume_adjustment!
    @company.create_integration_setting!(
      settings: { "adjust_volumes_for_subscription" => true }
    )
  end

  def build_volume_service(fake_variants:, fake_carts:, country_code: "US")
    cart = {
      "cart_token" => "ct_abc",
      "country_code" => country_code,
      "company" => { "id" => @company.fluid_company_id },
      "items" => [],
    }
    service = Callbacks::BaseService.new({ cart: cart })
    client = Object.new
    client.define_singleton_method(:variants) { fake_variants }
    client.define_singleton_method(:carts) { fake_carts }
    service.define_singleton_method(:fluid_client) { client }
    service
  end

  test "update_cart_items_volumes applies proportional volumes for subscription pricing" do
    enable_volume_adjustment!
    items = [ {
      "id" => 1, "variant_id" => 10, "price" => "100.0",
      "subscription_price" => "90.0", "quantity" => 1,
    } ]
    variants = FakeVariantsResource.new(10 => [ { "country_code" => "US", "cv" => 50, "qv" => 40, "price" => "100.0",
"subscription_price" => "90.0", } ])
    carts = FakeVolumeCartsResource.new
    service = build_volume_service(fake_variants: variants, fake_carts: carts)

    service.send(:update_cart_items_volumes, items, mode: :subscription)

    assert_equal 1, carts.volume_calls.size
    call = carts.volume_calls.first
    assert_equal "ct_abc", call[:token]
    assert_equal 1, call[:item_id]
    # ratio = (100-90)/100 = 0.1 -> 50*0.9 = 45, 40*0.9 = 36
    assert_equal({ "cv" => 45, "qv" => 36 }, call[:volumes])
  end

  test "update_cart_items_volumes does nothing when the toggle is off" do
    items = [ {
      "id" => 1, "variant_id" => 10, "price" => "100.0",
      "subscription_price" => "90.0", "quantity" => 1,
    } ]
    variants = FakeVariantsResource.new(10 => [ { "country_code" => "US", "cv" => 50, "qv" => 40, "price" => "100.0",
"subscription_price" => "90.0", } ])
    carts = FakeVolumeCartsResource.new
    service = build_volume_service(fake_variants: variants, fake_carts: carts)

    service.send(:update_cart_items_volumes, items, mode: :subscription)

    assert_equal 0, carts.volume_calls.size
  end

  test "update_cart_items_volumes skips items without a variant_id" do
    enable_volume_adjustment!
    items = [ { "id" => 1, "price" => "100.0", "subscription_price" => "90.0", "quantity" => 1 } ]
    variants = FakeVariantsResource.new({})
    carts = FakeVolumeCartsResource.new
    service = build_volume_service(fake_variants: variants, fake_carts: carts)

    service.send(:update_cart_items_volumes, items, mode: :subscription)

    assert_equal 0, carts.volume_calls.size
  end

  test "update_cart_items_volumes restores base volumes in regular mode" do
    enable_volume_adjustment!
    items = [ {
      "id" => 1, "variant_id" => 10, "price" => "100.0",
      "subscription_price" => "90.0", "quantity" => 1,
    } ]
    variants = FakeVariantsResource.new(10 => [ { "country_code" => "US", "cv" => 50, "qv" => 40, "price" => "100.0",
"subscription_price" => "90.0", } ])
    carts = FakeVolumeCartsResource.new
    service = build_volume_service(fake_variants: variants, fake_carts: carts)

    service.send(:update_cart_items_volumes, items, mode: :regular)

    assert_equal({ "cv" => 50, "qv" => 40 }, carts.volume_calls.first[:volumes])
  end

  test "update_cart_items_volumes keeps per-unit volume regardless of quantity" do
    enable_volume_adjustment!
    items = [ {
      "id" => 1, "variant_id" => 10, "price" => "100.0",
      "subscription_price" => "90.0", "quantity" => 3,
    } ]
    variants = FakeVariantsResource.new(10 => [ { "country_code" => "US", "cv" => 50, "qv" => 40, "price" => "100.0",
"subscription_price" => "90.0", } ])
    carts = FakeVolumeCartsResource.new
    service = build_volume_service(fake_variants: variants, fake_carts: carts)

    service.send(:update_cart_items_volumes, items, mode: :subscription)

    assert_equal({ "cv" => 45, "qv" => 36 }, carts.volume_calls.first[:volumes])
  end

  test "update_cart_items_volumes matches the cart country, falling back to the first entry" do
    enable_volume_adjustment!
    items = [ {
      "id" => 1, "variant_id" => 10, "price" => "100.0",
      "subscription_price" => "90.0", "quantity" => 1,
    } ]
    variants = FakeVariantsResource.new(10 => [
      { "country_code" => "US", "cv" => 50, "qv" => 40, "price" => "100.0", "subscription_price" => "90.0" },
      { "country_code" => "CA", "cv" => 20, "qv" => 10, "price" => "100.0", "subscription_price" => "90.0" },
    ])
    carts = FakeVolumeCartsResource.new
    service = build_volume_service(fake_variants: variants, fake_carts: carts, country_code: "CA")

    service.send(:update_cart_items_volumes, items, mode: :subscription)

    # ratio 0.1 on CA base: 20*0.9 = 18, 10*0.9 = 9
    assert_equal({ "cv" => 18, "qv" => 9 }, carts.volume_calls.first[:volumes])
  end

  # The discount ratio comes from the variant_country's own price /
  # subscription_price (authoritative source that also carries cv/qv), NOT the
  # cart item's price fields, which can be inconsistent/inverted (STU2-2526).
  test "update_cart_items_volumes derives the ratio from the variant, not the cart item" do
    enable_volume_adjustment!
    # Cart item prices are inverted (subscription > price), as seen in the real
    # sample cart; they must be ignored for the ratio.
    items = [ {
      "id" => 1, "variant" => { "id" => 10 }, "price" => "23.99",
      "subscription_price" => "29.99", "quantity" => 1,
    } ]
    variants = FakeVariantsResource.new(10 => [
      { "country_code" => "US", "cv" => 125, "qv" => 125, "price" => "29.99", "subscription_price" => "23.99" },
    ])
    carts = FakeVolumeCartsResource.new
    service = build_volume_service(fake_variants: variants, fake_carts: carts)

    service.send(:update_cart_items_volumes, items, mode: :subscription)

    # 125 * (23.99 / 29.99) = 99.98 -> 100
    assert_equal({ "cv" => 100, "qv" => 100 }, carts.volume_calls.first[:volumes])
  end

  # Fluid's real cart payload nests the variant id under "variant" and exposes
  # the country as an object (or via ship_to), not as flat variant_id /
  # country_code keys. See STU2-2526 sample cart.
  test "update_cart_items_volumes resolves variant_id nested under the variant object" do
    enable_volume_adjustment!
    items = [ {
      "id" => 1, "variant" => { "id" => 10 }, "price" => "100.0",
      "subscription_price" => "90.0", "quantity" => 1,
    } ]
    variants = FakeVariantsResource.new(10 => [ { "country_code" => "US", "cv" => 50, "qv" => 40, "price" => "100.0",
"subscription_price" => "90.0", } ])
    carts = FakeVolumeCartsResource.new
    service = build_volume_service(fake_variants: variants, fake_carts: carts)

    service.send(:update_cart_items_volumes, items, mode: :subscription)

    assert_equal 1, carts.volume_calls.size
    assert_equal({ "cv" => 45, "qv" => 36 }, carts.volume_calls.first[:volumes])
  end

  test "update_cart_items_volumes resolves the country from a country object (country.iso)" do
    enable_volume_adjustment!
    cart = {
      "cart_token" => "ct_abc",
      "country" => { "iso" => "CA" },
      "company" => { "id" => @company.fluid_company_id },
      "items" => [],
    }
    carts = FakeVolumeCartsResource.new
    variants = FakeVariantsResource.new(10 => [
      { "country_code" => "US", "cv" => 50, "qv" => 40, "price" => "100.0", "subscription_price" => "90.0" },
      { "country_code" => "CA", "cv" => 20, "qv" => 10, "price" => "100.0", "subscription_price" => "90.0" },
    ])
    client = Object.new
    client.define_singleton_method(:variants) { variants }
    client.define_singleton_method(:carts) { carts }
    service = Callbacks::BaseService.new({ cart: cart })
    service.define_singleton_method(:fluid_client) { client }

    items = [ {
      "id" => 1, "variant" => { "id" => 10 }, "price" => "100.0",
      "subscription_price" => "90.0", "quantity" => 1,
    } ]
    service.send(:update_cart_items_volumes, items, mode: :subscription)

    # CA base 20/10 with ratio 0.1 -> 18 / 9
    assert_equal({ "cv" => 18, "qv" => 9 }, carts.volume_calls.first[:volumes])
  end

  test "update_cart_items_volumes falls back to ship_to country_code" do
    enable_volume_adjustment!
    cart = {
      "cart_token" => "ct_abc",
      "ship_to" => { "country_code" => "CA" },
      "company" => { "id" => @company.fluid_company_id },
      "items" => [],
    }
    carts = FakeVolumeCartsResource.new
    variants = FakeVariantsResource.new(10 => [
      { "country_code" => "US", "cv" => 50, "qv" => 40, "price" => "100.0", "subscription_price" => "90.0" },
      { "country_code" => "CA", "cv" => 20, "qv" => 10, "price" => "100.0", "subscription_price" => "90.0" },
    ])
    client = Object.new
    client.define_singleton_method(:variants) { variants }
    client.define_singleton_method(:carts) { carts }
    service = Callbacks::BaseService.new({ cart: cart })
    service.define_singleton_method(:fluid_client) { client }

    items = [ {
      "id" => 1, "variant" => { "id" => 10 }, "price" => "100.0",
      "subscription_price" => "90.0", "quantity" => 1,
    } ]
    service.send(:update_cart_items_volumes, items, mode: :subscription)

    assert_equal({ "cv" => 18, "qv" => 9 }, carts.volume_calls.first[:volumes])
  end
end

class FakeVariantsResource
  def initialize(volumes_by_variant_id)
    @volumes_by_variant_id = volumes_by_variant_id
  end

  def get(variant_id)
    countries = @volumes_by_variant_id[variant_id] || []
    { "variant" => { "id" => variant_id, "variant_countries" => countries } }
  end
end

class FakeVolumeCartsResource
  attr_reader :volume_calls

  def initialize
    @volume_calls = []
  end

  def update_item_volumes(token, item_id, volumes)
    @volume_calls << { token: token, item_id: item_id, volumes: volumes }
    { "success" => true }
  end
end
