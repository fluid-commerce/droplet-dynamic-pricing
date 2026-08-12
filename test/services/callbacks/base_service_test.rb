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

  # --- price_type_wholesale? (STU2-2964) ---

  test "price_type_wholesale? is true when cart metadata.price_type is wholesale" do
    cart = @cart_data.deep_dup
    cart["metadata"] = { "price_type" => "wholesale" }
    service = Callbacks::BaseService.new({ cart: cart })

    assert service.send(:price_type_wholesale?)
  end

  test "price_type_wholesale? is false when price_type is something else" do
    cart = @cart_data.deep_dup
    cart["metadata"] = { "price_type" => "preferred_customer" }
    service = Callbacks::BaseService.new({ cart: cart })

    refute service.send(:price_type_wholesale?)
  end

  test "price_type_wholesale? is false when cart has no metadata at all" do
    service = Callbacks::BaseService.new({ cart: @cart_data })

    refute service.send(:price_type_wholesale?)
  end

  test "price_type_wholesale? is nil-safe when cart itself is nil" do
    service = Callbacks::BaseService.new({ cart: nil })

    refute service.send(:price_type_wholesale?)
  end

  test "price_type_wholesale? handles symbol-keyed metadata and price_type" do
    cart = @cart_data.deep_dup
    cart[:metadata] = { price_type: "wholesale" }
    service = Callbacks::BaseService.new({ cart: cart })

    assert service.send(:price_type_wholesale?)
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

  def enable_preferred_customer_volume_source!
    @company.create_integration_setting!(
      settings: {
        "adjust_volumes_for_subscription" => true,
        "subscription_volume_source" => "preferred_customer",
      }
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

  # --- subscription_volume_source (Oliabo pc_cv/pc_qv, STU2 / PRIMA) ---

  # Regression guard: the default "price_ratio" source keeps scaling the retail
  # cv/qv by the subscription discount. Oliabo's PRIMA numbers (100 retail,
  # 110/122 subscription) yield 90 — the WRONG value pc_cv/pc_qv fixes, but the
  # right one for every company that relies on the ratio behavior.
  test "update_cart_items_volumes default price_ratio source scales retail volumes by the discount" do
    enable_volume_adjustment!
    items = [ { "id" => 1, "variant_id" => 10, "quantity" => 1 } ]
    variants = FakeVariantsResource.new(10 => [ {
      "country_code" => "US", "cv" => 100, "qv" => 100,
      "pc_cv" => 100, "pc_qv" => 110,
      "price" => "122.0", "subscription_price" => "110.0",
    } ])
    carts = FakeVolumeCartsResource.new
    service = build_volume_service(fake_variants: variants, fake_carts: carts)

    service.send(:update_cart_items_volumes, items, mode: :subscription)

    # ratio 110/122 = 0.9016 -> round(100 * 0.9016) = 90 for both cv and qv
    assert_equal({ "cv" => 90, "qv" => 90 }, carts.volume_calls.first[:volumes])
  end

  test "update_cart_items_volumes preferred_customer source writes pc_cv/pc_qv directly" do
    enable_preferred_customer_volume_source!
    items = [ { "id" => 1, "variant_id" => 10, "quantity" => 1 } ]
    variants = FakeVariantsResource.new(10 => [ {
      "country_code" => "US", "cv" => 100, "qv" => 100,
      "pc_cv" => 100, "pc_qv" => 110,
      "price" => "122.0", "subscription_price" => "110.0",
    } ])
    carts = FakeVolumeCartsResource.new
    service = build_volume_service(fake_variants: variants, fake_carts: carts)

    service.send(:update_cart_items_volumes, items, mode: :subscription)

    # pc volumes written directly, NOT scaled by the price ratio
    assert_equal({ "cv" => 100, "qv" => 110 }, carts.volume_calls.first[:volumes])
  end

  test "update_cart_items_volumes preferred_customer source honors quantity per-unit" do
    enable_preferred_customer_volume_source!
    items = [ { "id" => 1, "variant_id" => 10, "quantity" => 3 } ]
    variants = FakeVariantsResource.new(10 => [ {
      "country_code" => "US", "cv" => 100, "qv" => 100,
      "pc_cv" => 100, "pc_qv" => 110,
      "price" => "122.0", "subscription_price" => "110.0",
    } ])
    carts = FakeVolumeCartsResource.new
    service = build_volume_service(fake_variants: variants, fake_carts: carts)

    service.send(:update_cart_items_volumes, items, mode: :subscription)

    # per-unit pc volumes, unaffected by quantity
    assert_equal({ "cv" => 100, "qv" => 110 }, carts.volume_calls.first[:volumes])
  end

  test "update_cart_items_volumes preferred_customer source writes retail volumes as-is when pc volumes are missing" do
    enable_preferred_customer_volume_source!
    items = [ { "id" => 1, "variant_id" => 10, "quantity" => 1 } ]
    # No pc_cv/pc_qv on the variant_country.
    variants = FakeVariantsResource.new(10 => [ {
      "country_code" => "US", "cv" => 100, "qv" => 100,
      "price" => "122.0", "subscription_price" => "110.0",
    } ])
    carts = FakeVolumeCartsResource.new
    service = build_volume_service(fake_variants: variants, fake_carts: carts)

    service.send(:update_cart_items_volumes, items, mode: :subscription)

    # pc missing -> write retail cv/qv as-is (100/100), NOT the price-ratio 90/90,
    # so a catalog misconfig is diagnosable rather than silently masked.
    assert_equal({ "cv" => 100, "qv" => 100 }, carts.volume_calls.first[:volumes])
  end

  # --- country-safe pricing (STU2-3108) ---
  #
  # Fixture mirrors the real variant from the incident: 278058 (10111-UNV) is
  # priced US $99.00 / CA $113.85 CAD / PH ₱2,499.00, which is what makes it able
  # to express every cross-country case.

  INCIDENT_VARIANT_ID = 278058
  INCIDENT_ROWS = [
    { "country_code" => "CA", "currency_code" => "CAD", "active" => true,
      "price" => "113.85", "subscription_price" => "113.85", "cv" => 0, "qv" => 0, },
    { "country_code" => "PH", "currency_code" => "PHP", "active" => true,
      "price" => "2499.0", "subscription_price" => "2499.0", "cv" => 0, "qv" => 0, },
    { "country_code" => "US", "currency_code" => "USD", "active" => true,
      "price" => "99.0", "subscription_price" => "99.0", "cv" => 0, "qv" => 0, },
  ].freeze

  # What Fluid's BundleGroupPricing.build_bundle_metadata stamps on a bundle group
  # cart item. "bundle_group_cv" is written unconditionally there, which is how the
  # droplet tells a group bundle (priced through bundle groups) from a legacy
  # ProductBundle item (priced through variant_country) — the same discriminator
  # Fluid's own ItemPricing#assign_volumes! uses.
  BUNDLE_GROUP_METADATA = {
    "is_bundle" => true,
    "bundled_items" => [],
    "bundle_group_cv" => 0,
    "bundle_group_qv" => 0,
  }.freeze

  def build_pricing_service(items:, country_code:, rows: { INCIDENT_VARIANT_ID => INCIDENT_ROWS })
    cart = {
      "cart_token" => "ct_abc",
      "country_code" => country_code,
      "company" => { "id" => @company.fluid_company_id },
      "items" => items,
    }.compact
    cart.delete("country_code") if country_code.nil?

    service = Callbacks::BaseService.new({ cart: cart })
    variants = FakeVariantsResource.new(rows)
    client = Object.new
    client.define_singleton_method(:variants) { variants }
    service.define_singleton_method(:fluid_client) { client }
    service.define_singleton_method(:fake_variants) { variants }
    service
  end

  test "cart_items_with_subscription_price writes the PH price when the payload carries CA's" do
    # The incident: Fluid sent 113.85 (CAD) for a Philippine cart.
    service = build_pricing_service(
      country_code: "PH",
      items: [ { "id" => 1, "variant_id" => INCIDENT_VARIANT_ID, "subscription_price" => "113.85" } ]
    )

    result = service.send(:cart_items_with_subscription_price)

    assert_equal 2499.0, result.first["price"]
    refute_equal 113.85, result.first["price"]
  end

  test "cart_items_with_subscription_price writes the US price when the payload carries PH's" do
    # The inverse case from the same session: 2,499 landed on a USD cart.
    service = build_pricing_service(
      country_code: "US",
      items: [ { "id" => 1, "variant_id" => INCIDENT_VARIANT_ID, "subscription_price" => "2499.0" } ]
    )

    result = service.send(:cart_items_with_subscription_price)

    assert_equal 99.0, result.first["price"]
  end

  test "cart_items_with_subscription_price leaves a correct payload price untouched" do
    service = build_pricing_service(
      country_code: "PH",
      items: [ { "id" => 1, "variant_id" => INCIDENT_VARIANT_ID, "subscription_price" => "2499.0" } ]
    )

    result = service.send(:cart_items_with_subscription_price)

    assert_equal 2499.0, result.first["price"]
  end

  test "cart_items_with_regular_price resolves the cart country's retail price" do
    service = build_pricing_service(
      country_code: "CA",
      items: [ { "id" => 1, "variant_id" => INCIDENT_VARIANT_ID,
                 "price" => "2499.0", "product" => { "price" => "2499.0" }, } ]
    )

    result = service.send(:cart_items_with_regular_price)

    assert_equal 113.85, result.first["price"]
  end

  test "cart_items_with_subscription_price refuses a payload price belonging to another country" do
    # The cart's own country row is unusable (0.0), so the payload is the only
    # candidate — and it turns out to be CA's figure. Refuse rather than lock it.
    rows = {
      INCIDENT_VARIANT_ID => [
        { "country_code" => "PH", "currency_code" => "PHP", "active" => true,
          "price" => "0.0", "subscription_price" => "0.0", },
        { "country_code" => "CA", "currency_code" => "CAD", "active" => true,
          "price" => "113.85", "subscription_price" => "113.85", },
      ],
    }
    service = build_pricing_service(
      country_code: "PH",
      items: [ { "id" => 1, "variant_id" => INCIDENT_VARIANT_ID, "subscription_price" => "113.85" } ],
      rows: rows
    )
    reported = []
    service.define_singleton_method(:report_exception) { |e, **ctx| reported << [ e, ctx ] }

    result = service.send(:cart_items_with_subscription_price)

    assert_empty result, "the item must be dropped from the batch, not written"
    assert_equal 1, reported.size
    assert_instance_of CrossCountryPriceError, reported.first[0]
    assert_equal "CA", reported.first[1][:foreign_country]
    assert_equal "PH", reported.first[1][:cart_country]
  end

  test "cart_items_with_subscription_price keeps bundle parents priced from cart item metadata" do
    # A bundle parent is 0.0 on every country row; the real figure rides in the
    # cart item's metadata. It must still be repriced, not dropped.
    bundle_variant_id = 285690
    rows = {
      bundle_variant_id => [
        { "country_code" => "CA", "currency_code" => "CAD", "active" => true,
          "price" => "0.0", "subscription_price" => "0.0", },
        { "country_code" => "US", "currency_code" => "USD", "active" => true,
          "price" => "0.0", "subscription_price" => "0.0", },
      ],
    }
    service = build_pricing_service(
      country_code: "CA",
      items: [ { "id" => 1, "variant_id" => bundle_variant_id, "subscription_price" => "0.0",
                 "price" => "246.99", "metadata" => { "bundle_group_base_price" => "172.99" }, } ],
      rows: rows
    )

    result = service.send(:cart_items_with_subscription_price)

    assert_equal 1, result.size
    assert_equal "172.99", result.first["price"]
  end

  test "a bundle group line keeps its bundle figure even when the master variant is priced" do
    # Verified against real data rather than assumed: the local bundle's master
    # variant (33693) carries a positive row for every country — 99.00 US /
    # 113.85 CA / 2499.00 MX — while its cart items sit at a metadata base price of
    # 0.0. Reading the row would write 99.00 onto a line Fluid prices at zero and
    # then lock it. Fluid never prices a bundle group item from variant_country
    # (ItemPricing#use_bundle_group_pricing?), so neither may we.
    service = build_pricing_service(
      country_code: "US",
      items: [ { "id" => 1, "variant_id" => INCIDENT_VARIANT_ID, "subscription_price" => "0.0",
                 "price" => "246.99",
                 "metadata" => BUNDLE_GROUP_METADATA.merge("bundle_group_base_price" => "172.99"), } ]
    )

    result = service.send(:cart_items_with_subscription_price)

    assert_equal "172.99", result.first["price"]
    refute_equal 99.0, result.first["price"], "must not read the master variant's country row"
  end

  test "a bundle group line with no cached base price still bypasses the country row" do
    # Fluid's gate is `bundle_group_base_price.present? || product_bundle_groups.any?`.
    # A bundle added in a country with no enabled entry lands with the base price
    # missing and Fluid still prices it through bundle groups, so the presence of
    # "bundle_group_cv" has to be enough on its own.
    metadata = BUNDLE_GROUP_METADATA.dup
    service = build_pricing_service(
      country_code: "US",
      items: [ { "id" => 1, "variant_id" => INCIDENT_VARIANT_ID, "subscription_price" => "150.0",
                 "metadata" => metadata, } ]
    )

    result = service.send(:cart_items_with_subscription_price)

    assert_equal "150.0", result.first["price"], "the payload price is Fluid's bundle figure"
    refute_equal 99.0, result.first["price"]
  end

  test "a legacy bundle line still prices from the country row" do
    # Legacy ProductBundle items get "is_bundle" and "bundled_items" but never
    # "bundle_group_cv" (item_service.rb#build_legacy_bundle_metadata!), and Fluid
    # prices them through variant_country like any other item. So must we —
    # otherwise they lose the STU2-3108 protection.
    service = build_pricing_service(
      country_code: "PH",
      items: [ { "id" => 1, "variant_id" => INCIDENT_VARIANT_ID, "subscription_price" => "113.85",
                 "metadata" => { "is_bundle" => true, "bundled_items" => [] }, } ]
    )

    result = service.send(:cart_items_with_subscription_price)

    assert_equal 2499.0, result.first["price"]
  end

  test "cart_items_with_subscription_price skips the item when the cart country cannot be resolved" do
    service = build_pricing_service(
      country_code: nil,
      items: [ { "id" => 1, "variant_id" => INCIDENT_VARIANT_ID, "subscription_price" => "113.85" } ]
    )

    result = service.send(:cart_items_with_subscription_price)

    assert_empty result, "no country means no safe price — skip rather than guess"
  end

  test "variant_country_row never falls back to another country's row" do
    # Cart is in a country the variant has no row for. The old `|| countries.first`
    # would have adopted CA's row (price AND volumes).
    service = build_pricing_service(
      country_code: "MX",
      items: [ { "id" => 1, "variant_id" => INCIDENT_VARIANT_ID } ]
    )

    assert_nil service.send(:variant_country_row, INCIDENT_VARIANT_ID)
    assert_nil service.send(:variant_base_volumes, INCIDENT_VARIANT_ID)
  end

  test "variant country rows are fetched once per variant across several cart items" do
    service = build_pricing_service(
      country_code: "PH",
      items: [
        { "id" => 1, "variant_id" => INCIDENT_VARIANT_ID, "subscription_price" => "113.85" },
        { "id" => 2, "variant_id" => INCIDENT_VARIANT_ID, "subscription_price" => "113.85" },
        { "id" => 3, "variant_id" => INCIDENT_VARIANT_ID, "subscription_price" => "113.85" },
      ]
    )

    service.send(:cart_items_with_subscription_price)

    assert_equal [ INCIDENT_VARIANT_ID ], service.send(:fake_variants).get_calls
  end

  test "an inactive row for the cart's country is not used, even when it carries a price" do
    # `active` off is the company saying the variant is not sold in that country.
    # Fluid resolves through variant_countries.active (cart_item.rb:346-352), so
    # its answer to "what does this cost here?" is "nothing" — ours has to match,
    # or the droplet writes a switched-off figure and locks it. Doesn't occur in
    # the catalogs checked (deactivated rows sit at 0.00), but the rule is the
    # rule.
    rows = { INCIDENT_VARIANT_ID => [
      { "country_code" => "CA", "currency_code" => "CAD", "active" => false,
        "price" => "64.97", "subscription_price" => "44.97", },
    ] }
    service = build_pricing_service(
      country_code: "CA",
      items: [ { "id" => 1, "variant_id" => INCIDENT_VARIANT_ID, "subscription_price" => "44.97" } ],
      rows: rows
    )

    assert_nil service.send(:variant_country_row, INCIDENT_VARIANT_ID)
    assert_nil service.send(:variant_base_volumes, INCIDENT_VARIANT_ID),
               "volumes must skip the item too, not fall back to another country"
  end

  test "subscribe-and-save discount still applies (55.97 -> 38.97)" do
    rows = { 278059 => [ { "country_code" => "US", "currency_code" => "USD", "active" => true,
                           "price" => "55.97", "subscription_price" => "38.97", } ] }
    service = build_pricing_service(
      country_code: "US",
      items: [ { "id" => 1, "variant_id" => 278059, "subscription_price" => "38.97",
                 "price" => "55.97", "product" => { "price" => "55.97" }, } ],
      rows: rows
    )

    assert_equal 38.97, service.send(:cart_items_with_subscription_price).first["price"]
    assert_equal 55.97, service.send(:cart_items_with_regular_price).first["price"]
  end

  test "update_item_to_subscription_price treats a bundle's 0.0 subscription_price as zero, not truthy" do
    # "0.0" is a truthy String: a plain `||` chain would stop there, write zero,
    # and let the zero-price guard drop the line — silently cancelling the
    # reprice. It must fall through to the bundle base price instead, matching
    # cart_items_with_subscription_price.
    bundle_variant_id = 285690
    rows = { bundle_variant_id => [ { "country_code" => "CA", "currency_code" => "CAD", "active" => true,
                                      "price" => "0.0", "subscription_price" => "0.0", } ] }
    cart_item = { "id" => 1, "variant_id" => bundle_variant_id, "subscription_price" => "0.0",
                  "price" => "246.99", "metadata" => { "bundle_group_base_price" => "172.99" }, }
    service = build_pricing_service(country_code: "CA", items: [ cart_item ], rows: rows)
    service.define_singleton_method(:cart_item) { cart_item }
    written = []
    carts = Object.new
    carts.define_singleton_method(:update_items_prices) { |_token, items| written.concat(items) }
    client = service.send(:fluid_client)
    client.define_singleton_method(:carts) { carts }
    service.define_singleton_method(:update_cart_items_volumes) { |*| nil }

    service.send(:update_item_to_subscription_price)

    assert_equal [ { "id" => 1, "price" => "172.99" } ], written
  end

  # --- stranded lines after a country change (the lock interaction) ---

  test "update_item_to_subscription_price also corrects other lines stranded in another country" do
    # The cart moved to PH after an earlier write locked the CA figure on item 2.
    # Fluid cannot re-resolve a locked line, so only the droplet can fix it — and a
    # callback names just item 1, so item 2 has to be swept.
    cart_item = { "id" => 1, "variant_id" => INCIDENT_VARIANT_ID, "subscription_price" => "2499.0" }
    stranded  = { "id" => 2, "variant_id" => INCIDENT_VARIANT_ID, "price" => "113.85" }
    service = build_pricing_service(country_code: "PH", items: [ cart_item, stranded ])
    service.define_singleton_method(:cart_item) { cart_item }
    written = []
    carts = Object.new
    carts.define_singleton_method(:update_items_prices) { |_token, items| written.concat(items) }
    service.send(:fluid_client).define_singleton_method(:carts) { carts }
    service.define_singleton_method(:update_cart_items_volumes) { |*| nil }

    service.send(:update_item_to_subscription_price)

    assert_equal [ { "id" => 1, "price" => 2499.0 }, { "id" => 2, "price" => 2499.0 } ], written
  end

  test "the sweep is a no-op when every line already matches the cart's country" do
    cart_item = { "id" => 1, "variant_id" => INCIDENT_VARIANT_ID, "subscription_price" => "2499.0" }
    healthy   = { "id" => 2, "variant_id" => INCIDENT_VARIANT_ID, "price" => "2499.0" }
    service = build_pricing_service(country_code: "PH", items: [ cart_item, healthy ])

    assert_empty service.send(:stranded_cart_lines, except_item_id: 1)
  end

  test "the sweep leaves bundle group lines alone even when the master variant is priced" do
    # A bundle's master variant carrying a priced row is not hypothetical: the
    # local bundle's master (33693) is 99.00 US / 113.85 CA / 2499.00 MX while its
    # cart items sit at a metadata base price of 0.0. Without the bundle gate the
    # sweep would "correct" a bundle line to the master variant's figure.
    items = [
      { "id" => 1, "variant_id" => INCIDENT_VARIANT_ID, "subscription_price" => "2499.0" },
      { "id" => 2, "variant_id" => INCIDENT_VARIANT_ID, "price" => "172.99",
        "metadata" => BUNDLE_GROUP_METADATA.merge("bundle_group_base_price" => "172.99"), },
    ]
    service = build_pricing_service(country_code: "PH", items: items)

    assert_empty service.send(:stranded_cart_lines, except_item_id: 1)
  end

  test "the sweep refreshes the volumes of the lines it corrects, not only their prices" do
    # Fluid's update_volumes endpoint stamps cv_manually_updated, which makes its
    # own ItemPricing skip the line forever — the volumes analogue of the price
    # lock. A swept line whose CV/QV were written under the old country would keep
    # them otherwise.
    cart_item = { "id" => 1, "variant_id" => INCIDENT_VARIANT_ID, "subscription_price" => "2499.0" }
    stranded  = { "id" => 2, "variant_id" => INCIDENT_VARIANT_ID, "price" => "113.85" }
    service = build_pricing_service(country_code: "PH", items: [ cart_item, stranded ])
    service.define_singleton_method(:cart_item) { cart_item }
    carts = Object.new
    carts.define_singleton_method(:update_items_prices) { |_token, _items| nil }
    service.send(:fluid_client).define_singleton_method(:carts) { carts }
    volume_items = []
    service.define_singleton_method(:update_cart_items_volumes) { |items, **| volume_items.concat(items) }

    service.send(:update_item_to_subscription_price)

    assert_equal [ 1, 2 ], volume_items.map { |item| item["id"] }
  end

  test "the sweep does nothing when the cart country cannot be resolved" do
    items = [
      { "id" => 1, "variant_id" => INCIDENT_VARIANT_ID, "subscription_price" => "2499.0" },
      { "id" => 2, "variant_id" => INCIDENT_VARIANT_ID, "price" => "113.85" },
    ]
    service = build_pricing_service(country_code: nil, items: items)

    assert_empty service.send(:stranded_cart_lines, except_item_id: 1)
  end

  test "a failed variant lookup falls through to the payload rather than blocking the reprice" do
    service = build_pricing_service(
      country_code: "PH",
      items: [ { "id" => 1, "variant_id" => 999, "subscription_price" => "2499.0" } ],
      rows: {}
    )

    result = service.send(:cart_items_with_subscription_price)

    # Forwarded as given, not coerced: the payload path stays byte-identical to
    # what Fluid sent, so a passthrough can't introduce a rounding difference of
    # its own.
    assert_equal "2499.0", result.first["price"]
  end
end

class FakeVariantsResource
  attr_reader :get_calls

  def initialize(volumes_by_variant_id)
    @volumes_by_variant_id = volumes_by_variant_id
    @get_calls = []
  end

  def get(variant_id)
    @get_calls << variant_id
    countries = (@volumes_by_variant_id[variant_id] || []).map do |row|
      # Fluid's v1 endpoint always emits `active` on a country row
      # (V1::VariantCountryBlueprinter), so a fixture that omits it stands for an
      # ACTIVE row, not an absent flag. Fixtures testing the inactive path set it
      # explicitly.
      row.key?("active") || row.key?(:active) ? row : row.merge("active" => true)
    end
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
