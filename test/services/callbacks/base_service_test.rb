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

    assert_equal 333.0, result.first["price"]
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

    assert_equal 333.0, result.first["price"]
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
  # The variant from the incident: 278058, US 99.00 / CA 113.85 / PH 2,499.00.

  INCIDENT_VARIANT_ID = 278058
  INCIDENT_ROWS = [
    { "country_code" => "CA", "currency_code" => "CAD", "active" => true,
      "price" => "113.85", "subscription_price" => "113.85", "cv" => 0, "qv" => 0, },
    { "country_code" => "PH", "currency_code" => "PHP", "active" => true,
      "price" => "2499.0", "subscription_price" => "2499.0", "cv" => 0, "qv" => 0, },
    { "country_code" => "US", "currency_code" => "USD", "active" => true,
      "price" => "99.0", "subscription_price" => "99.0", "cv" => 0, "qv" => 0, },
  ].freeze

  # What BundleGroupPricing.build_bundle_metadata stamps on a bundle group item.
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

  test "a product not sold in the cart's country is dropped quietly, not reported" do
    # Yoli's dominant shape: one product per country, 220 of its 304 variants. Pure US
    # (278088) has all three rows — Fluid creates one per company country — but only US
    # is active; PH sits inactive at 0.00. So in a Philippine cart the line carries the
    # US figure and has no ACTIVE PH row, Fluid prices nothing, marks it unavailable and
    # blocks checkout. The customer changes country or drops the product; there is
    # nothing to action, and alerting would bury the real signal under the normal case.
    #
    # Observed in production on 2026-08-13: cart ct_WSYg6...NyR8 moved to PH, Yoli+
    # correctly repriced to 2,499, and this line raised a CrossCountryPriceError that
    # nobody could act on. Its own message said so — "whose subscription_price is nil".
    pure_us = 278088
    rows = { pure_us => [
      { "country_code" => "US", "currency_code" => "USD", "active" => true,
        "price" => "55.97", "subscription_price" => "38.97", },
      { "country_code" => "PH", "currency_code" => "PHP", "active" => false,
        "price" => "0.0", "subscription_price" => "0.0", },
    ] }
    service = build_pricing_service(
      country_code: "PH",
      items: [ { "id" => 1066779, "variant_id" => pure_us, "subscription_price" => "38.97" } ],
      rows: rows
    )
    reported = []
    service.define_singleton_method(:report_exception) { |e, **ctx| reported << [ e, ctx ] }

    result = service.send(:cart_items_with_subscription_price)

    assert_empty result, "still dropped — we must not write another country's figure"
    assert_empty reported, "but not paged about: the line cannot be bought here at all"
  end

  test "a price the cart's own country can explain is never called foreign" do
    # Oliabo, 2026-08-14, cart 757644. A US cart with a buyer_rep holding "Premium
    # Opportunity Cards" (SW-00003, allow_subscription false) was handed 100.00. That
    # is the US row's `wholesale`: unsubscribable collapses the subscription figure
    # onto the regular one, and a rep on the cart moves the regular one to the
    # wholesale column (CartItem#resolve_regular_price). Fluid's own answer for this
    # cart, in other words. AU also carried 100.00, so checking only other countries
    # called it foreign, refused a correct write and raised an alert nobody could act
    # on. The cart's own row explains the number, so it cannot have come from AU.
    variant = 280985
    rows = { variant => [
      { "country_code" => "US", "currency_code" => "USD", "active" => true,
        "price" => "0.0", "subscription_price" => "0.0",
        "wholesale" => "100.0", "wholesale_subscription_price" => "0.0", },
      { "country_code" => "AU", "currency_code" => "USD", "active" => true,
        "price" => "100.0", "subscription_price" => "100.0", },
    ] }
    service = build_pricing_service(
      country_code: "US",
      items: [ { "id" => 1067417, "variant_id" => variant, "subscription_price" => "100.0",
                 "price" => "100.0", "allow_subscription" => false, } ],
      rows: rows
    )
    reported = []
    service.define_singleton_method(:report_exception) { |e, **ctx| reported << [ e, ctx ] }

    result = service.send(:cart_items_with_subscription_price)

    assert_equal 100.0, result.first["price"], "Fluid's own figure for this cart must stand"
    assert_empty reported, "and nobody should be paged about it"
  end

  test "the incident is still caught once the cart's own row is checked first" do
    # The guard above must not blunt the case this ticket exists for. PH carries 2,499
    # in every column, so CA's 113.85 is unexplainable by the cart's own row and stays
    # foreign.
    service = build_pricing_service(
      country_code: "PH",
      items: [ { "id" => 1, "variant_id" => INCIDENT_VARIANT_ID, "subscription_price" => "113.85" } ]
    )

    assert_equal 2499.0, service.send(:cart_items_with_subscription_price).first["price"]
  end

  test "a variant sold here with no price configured is still reported" do
    # The other half of the split. An active row for the cart's country means Fluid
    # does sell the variant there, so a row sitting at 0.00 is a catalog problem
    # someone should see — unlike a product that simply isn't sold in the country.
    rows = { INCIDENT_VARIANT_ID => [
      { "country_code" => "PH", "currency_code" => "PHP", "active" => true,
        "price" => "0.0", "subscription_price" => "0.0", },
      { "country_code" => "CA", "currency_code" => "CAD", "active" => true,
        "price" => "113.85", "subscription_price" => "113.85", },
    ] }
    service = build_pricing_service(
      country_code: "PH",
      items: [ { "id" => 1, "variant_id" => INCIDENT_VARIANT_ID, "subscription_price" => "113.85" } ],
      rows: rows
    )
    reported = []
    service.define_singleton_method(:report_exception) { |e, **ctx| reported << [ e, ctx ] }

    assert_empty service.send(:cart_items_with_subscription_price)
    assert_equal 1, reported.size, "sold here, priced nowhere — worth an alert"
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
    assert_equal 172.99, result.first["price"]
  end

  test "a bundle group line keeps its bundle figure even when the master variant is priced" do
    # The local bundle's master (33693) is priced in all three countries while its
    # lines sit at 0.0, so reading the row would lock 99.00 onto a zero-priced line.
    service = build_pricing_service(
      country_code: "US",
      items: [ { "id" => 1, "variant_id" => INCIDENT_VARIANT_ID, "subscription_price" => "0.0",
                 "price" => "246.99",
                 "metadata" => BUNDLE_GROUP_METADATA.merge("bundle_group_base_price" => "172.99"), } ]
    )

    result = service.send(:cart_items_with_subscription_price)

    assert_equal 172.99, result.first["price"]
    refute_equal 99.0, result.first["price"], "must not read the master variant's country row"
  end

  test "a bundle group line with no cached base price still bypasses the country row" do
    # A bundle added in a country with no enabled entry lands with no base price and
    # is still bundle-priced, so "bundle_group_cv" has to be enough on its own.
    metadata = BUNDLE_GROUP_METADATA.dup
    service = build_pricing_service(
      country_code: "US",
      items: [ { "id" => 1, "variant_id" => INCIDENT_VARIANT_ID, "subscription_price" => "150.0",
                 "metadata" => metadata, } ]
    )

    result = service.send(:cart_items_with_subscription_price)

    assert_equal 150.0, result.first["price"], "the payload price is Fluid's bundle figure"
    refute_equal 99.0, result.first["price"]
  end

  test "any bundle line is left to Fluid, legacy ones included" do
    # Telling a legacy bundle from a bundle-group one fails in the dangerous
    # direction. Legacy bundles lose the country correction, but forwarding the
    # payload leaves the line unlocked for Fluid to resolve.
    service = build_pricing_service(
      country_code: "PH",
      items: [ { "id" => 1, "variant_id" => INCIDENT_VARIANT_ID, "subscription_price" => "113.85",
                 "metadata" => { "is_bundle" => true, "bundled_items" => [] }, } ]
    )

    result = service.send(:cart_items_with_subscription_price)

    assert_equal 113.85, result.first["price"]
  end

  test "an unresolvable pricing country warns and forwards the payload, for now" do
    # Staged: warn now, measure how often it fires, then refuse. Refusing outright
    # would stop repricing a guest cart with no address yet.
    service = build_pricing_service(
      country_code: nil,
      items: [ { "id" => 1, "variant_id" => INCIDENT_VARIANT_ID, "subscription_price" => "113.85" } ]
    )
    warnings = []
    service.define_singleton_method(:warn_line) { |msg| warnings << msg }
    Rails.logger.stub(:warn, ->(msg) { warnings << msg }) do
      assert_equal 113.85, service.send(:cart_items_with_subscription_price).first["price"]
    end

    assert warnings.any? { |w| w.to_s.include?("Cannot resolve the pricing country") },
           "the discrepancy has to be recorded even while we forward the payload"
  end

  test "a price is never resolved from the shipping country" do
    # cart_country accepts ship_to for volumes (STU2-2526); resolving a PRICE that
    # way is the bug this ticket is about, since the currency comes from the cart.
    cart = {
      "cart_token" => "ct_abc",
      "company" => { "id" => @company.fluid_company_id },
      "ship_to" => { "country_code" => "CA" },
      "items" => [ { "id" => 1, "variant_id" => INCIDENT_VARIANT_ID } ],
    }
    service = Callbacks::BaseService.new({ cart: cart })

    assert_equal "CA", service.send(:cart_country), "volumes still see ship_to"
    assert_nil service.send(:cart_pricing_country), "prices must not"
    assert_nil service.send(:variant_country_row, INCIDENT_VARIANT_ID)
  end

  test "variant_country_row never falls back to another country's row" do
    # No row for the cart's country means no price. Volumes keep their own
    # resolution (STU2-2526) and still fall back.
    service = build_pricing_service(
      country_code: "MX",
      items: [ { "id" => 1, "variant_id" => INCIDENT_VARIANT_ID } ]
    )

    assert_nil service.send(:variant_country_row, INCIDENT_VARIANT_ID)
    assert_equal "113.85", service.send(:variant_base_volumes, INCIDENT_VARIANT_ID)[:price],
                 "volumes are STU2-2526's and unchanged by this ticket"
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
    # `active` off means the company doesn't sell it there, and Fluid resolves
    # through variant_countries.active — so there is no price for us to write.
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
    # "0.0" is a truthy String, so a plain `||` would write zero and let the
    # zero-price guard drop the line, silently cancelling the reprice.
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

    assert_equal [ { "id" => 1, "price" => 172.99 } ], written
  end

  test "update_item_to_subscription_price writes only the item the callback names" do
    # Lines left behind in a previous country are CartCountryChangedService's.
    # Widening this path would mean guessing which other lines are stale, and
    # locking a price Fluid never set when the guess is wrong.
    cart_item = { "id" => 1, "variant_id" => INCIDENT_VARIANT_ID, "subscription_price" => "2499.0" }
    other = { "id" => 2, "variant_id" => INCIDENT_VARIANT_ID, "price" => "113.85",
              "subscription_price" => "2499.0", }
    service = build_pricing_service(country_code: "PH", items: [ cart_item, other ])
    service.define_singleton_method(:cart_item) { cart_item }
    written = []
    carts = Object.new
    carts.define_singleton_method(:update_items_prices) { |_token, items| written.concat(items) }
    service.send(:fluid_client).define_singleton_method(:carts) { carts }
    volume_items = []
    service.define_singleton_method(:update_cart_items_volumes) { |items, **| volume_items.concat(items) }

    service.send(:update_item_to_subscription_price)

    assert_equal [ { "id" => 1, "price" => 2499.0 } ], written
    assert_equal [ 1 ], volume_items.map { |item| item["id"] }
  end

  test "a country row with no active flag counts as active" do
    # Reading an absent key as "not sold" would stop pricing everything at once.
    rows = { INCIDENT_VARIANT_ID => [
      { "country_code" => "PH", "currency_code" => "PHP", "price" => "2499.0",
        "subscription_price" => "2499.0", },
      { "country_code" => "CA", "currency_code" => "CAD", "active" => true,
        "price" => "113.85", "subscription_price" => "113.85", },
    ] }
    service = build_pricing_service(
      country_code: "PH",
      items: [ { "id" => 1, "variant_id" => INCIDENT_VARIANT_ID, "subscription_price" => "113.85" } ],
      rows: rows
    )

    assert_equal 2499.0, service.send(:cart_items_with_subscription_price).first["price"]
  end

  test "a price Fluid resolved for this cart is left alone even when the row differs" do
    # Fluid reaches a price through more than the variant_country columns: a
    # percentage subscription plan computes off the retail price and ignores the
    # subscription_price column entirely (SubscriptionPriceCalculator), and a
    # wholesale rep reads the wholesale columns. Overwriting its figure with the row
    # would lock in a number Fluid never charges — a wider bug than the one this
    # ticket is about, and one that fires on every cart, not only on a country move.
    #
    # 44.99 is 25% off the US retail row and belongs to no country, so there is no
    # evidence of a leak and the droplet stays out of it.
    rows = { 278059 => [
      { "country_code" => "US", "currency_code" => "USD", "active" => true,
        "price" => "59.99", "subscription_price" => "49.99", },
      { "country_code" => "CA", "currency_code" => "CAD", "active" => true,
        "price" => "79.99", "subscription_price" => "69.99", },
    ] }
    service = build_pricing_service(
      country_code: "US",
      items: [ { "id" => 1, "variant_id" => 278059, "subscription_price" => "44.99" } ],
      rows: rows
    )

    assert_equal 44.99, service.send(:cart_items_with_subscription_price).first["price"],
                 "must not overwrite Fluid's plan-aware price with the catalog column"
  end

  test "a price that belongs to another country is still corrected" do
    # The counterpart: 69.99 IS CA's figure, so the cart's own row wins.
    rows = { 278059 => [
      { "country_code" => "US", "currency_code" => "USD", "active" => true,
        "price" => "59.99", "subscription_price" => "49.99", },
      { "country_code" => "CA", "currency_code" => "CAD", "active" => true,
        "price" => "79.99", "subscription_price" => "69.99", },
    ] }
    service = build_pricing_service(
      country_code: "US",
      items: [ { "id" => 1, "variant_id" => 278059, "subscription_price" => "69.99" } ],
      rows: rows
    )

    assert_equal 49.99, service.send(:cart_items_with_subscription_price).first["price"]
  end

  test "a failed variant lookup falls through to the payload rather than blocking the reprice" do
    service = build_pricing_service(
      country_code: "PH",
      items: [ { "id" => 1, "variant_id" => 999, "subscription_price" => "2499.0" } ],
      rows: {}
    )

    result = service.send(:cart_items_with_subscription_price)

    assert_equal 2499.0, result.first["price"]
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
    { "variant" => { "id" => variant_id, "variant_countries" => @volumes_by_variant_id[variant_id] || [] } }
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
