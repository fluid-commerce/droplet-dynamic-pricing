require "test_helper"

class Callbacks::CartCountryChangedServiceTest < ActiveSupport::TestCase
  include VolumeTestHelpers

  fixtures(:companies)

  def company
    companies(:acme)
  end

  LOCKED = { "price_locked" => true }.freeze

  # A PH cart still holding the figure locked while it was in US: subscription_price
  # is the new country's number, item.price the stale one.
  def cart_data(price_type: "preferred_customer")
    {
      "id" => 265327,
      "cart_token" => "ct_52blT6sVvSo4Ck2ygrKyW2",
      "customer_id" => 12345,
      "country" => { "iso" => "PH" },
      "currency_code" => "PHP",
      "metadata" => { "price_type" => price_type }.compact,
      "company" => {
        "id" => company.fluid_company_id,
        "name" => company.name,
        "subdomain" => "test",
      },
      "items" => [
        { "id" => 674137, "price" => "99.0", "subscription_price" => "2499.0",
          "metadata" => LOCKED, },
        { "id" => 674138, "price" => "113.85", "subscription_price" => "1999.0",
          "metadata" => LOCKED, },
      ],
    }
  end

  def callback_params(price_type: "preferred_customer")
    {
      "cart" => cart_data(price_type: price_type),
      "context" => {
        "company_id" => company.fluid_company_id,
        "country_code" => "PH",
        "previous_country_code" => "US",
        "currency_code" => "PHP",
        "previous_currency_code" => "USD",
      },
    }.with_indifferent_access
  end

  def stub_client(carts_resource)
    client = Object.new
    client.define_singleton_method(:carts) { carts_resource }
    client
  end

  def test_call_returns_error_when_cart_is_blank
    result = Callbacks::CartCountryChangedService.new({ cart: nil }).call

    assert_equal({ success: false, message: "Cart is blank" }, result)
  end

  def test_rewrites_every_line_at_the_new_countrys_price
    written = []
    carts = Object.new
    carts.define_singleton_method(:update_items_prices) { |_token, items| written.concat(items); { "success" => true } }
    carts.define_singleton_method(:append_metadata) { |_token, _metadata| { "success" => true } }

    service = Callbacks::CartCountryChangedService.new(callback_params)

    FluidClient.stub(:new, ->(_token) { stub_client(carts) }) do
      result = service.call
      assert result[:success], result.inspect
    end

    prices = written.to_h { |item| [ item["id"], item["price"].to_f ] }
    assert_equal 2499.0, prices[674137], "the line locked at the US figure has to move to PH's"
    assert_equal 1999.0, prices[674138]
  end

  def test_reasserts_the_preferred_customer_slug_so_the_price_type_cannot_drift
    # Price and slug travel on separate channels; leaving the slug behind produces
    # an order priced as preferred but labelled retail.
    service = Callbacks::CartCountryChangedService.new(callback_params)
    carts = Object.new
    carts.define_singleton_method(:update_items_prices) { |_token, _items| { "success" => true } }
    carts.define_singleton_method(:append_metadata) { |_token, _metadata| { "success" => true } }

    result = FluidClient.stub(:new, ->(_token) { stub_client(carts) }) { service.call }

    assert_equal "preferred_customer", result.dig(:metadata, "price_type")
  end

  def test_leaves_a_cart_with_no_locked_lines_alone
    # Nothing carries our stamp, so core already repriced every line at the new
    # country. Writing would only lock a price Fluid set itself.
    params = callback_params
    params["cart"]["items"].each { |item| item.delete("metadata") }
    carts = Object.new
    carts.define_singleton_method(:update_items_prices) { |_token, _items| flunk "nothing was locked" }
    carts.define_singleton_method(:append_metadata) { |_token, _metadata| flunk "nothing was locked" }

    service = Callbacks::CartCountryChangedService.new(params)

    result = FluidClient.stub(:new, ->(_token) { stub_client(carts) }) { service.call }

    assert result[:success]
  end

  def test_repairs_a_detached_carts_locked_lines_at_the_retail_price
    # A detached cart carries lines this droplet locked at RETAIL
    # (CartCustomerDetachedService sets price_type nil and writes anyway), and they
    # strand on a country change exactly like the preferred ones. Gating the repair
    # on preferred pricing would leave this whole branch broken.
    params = callback_params(price_type: nil)
    params["cart"].delete("customer_id")
    params["cart"]["items"] = [
      { "id" => 674137, "variant_id" => 10, "price" => "99.0",
        "product" => { "price" => "99.0" }, "metadata" => LOCKED, },
    ]

    written = []
    carts = Object.new
    carts.define_singleton_method(:update_items_prices) { |_token, items| written.concat(items); { "success" => true } }
    carts.define_singleton_method(:append_metadata) { |_token, _metadata| { "success" => true } }
    variants = VolumeTestHelpers::FakeVariants.new(
      10 => [ { "country_code" => "US", "currency_code" => "USD", "price" => "99.0",
                "subscription_price" => "79.0", },
              { "country_code" => "PH", "currency_code" => "PHP", "price" => "2499.0",
                "subscription_price" => "1999.0", }, ]
    )
    client = stub_client(carts)
    client.define_singleton_method(:variants) { variants }

    service = Callbacks::CartCountryChangedService.new(params)

    result = FluidClient.stub(:new, ->(_token) { client }) { service.call }

    assert result[:success]
    assert_equal [ { "id" => 674137, "price" => 2499.0 } ], written,
                 "the retail line has to move to PH's retail figure, not PH's subscription one"
    assert_nil result.dig(:metadata, "price_type"), "a detached cart must not be re-stamped preferred"
  end

  def test_does_nothing_on_an_empty_cart
    params = callback_params
    params["cart"]["items"] = []
    carts = Object.new
    carts.define_singleton_method(:update_items_prices) { |_token, _items| flunk "no items to reprice" }

    service = Callbacks::CartCountryChangedService.new(params)

    result = FluidClient.stub(:new, ->(_token) { stub_client(carts) }) { service.call }

    assert result[:success]
  end

  def test_yields_to_the_wholesale_droplet_on_an_unlocked_cart
    # yoli-promos owns WHOLESALE-unlock carts (STU2-2964); two droplets writing
    # the same lines would fight over them.
    params = callback_params
    params["cart"]["metadata"]["price_type"] = "wholesale"
    carts = Object.new
    carts.define_singleton_method(:update_items_prices) { |_token, _items| flunk "must yield to yoli-promos" }

    service = Callbacks::CartCountryChangedService.new(params)

    result = FluidClient.stub(:new, ->(_token) { stub_client(carts) }) { service.call }

    assert result[:success]
  end

  def test_records_the_reprice_as_a_country_changed_pricing_event
    # log_cart_pricing_event swallows its own failures, so an event_type missing
    # from the enum degrades to a log line — and the dashboard is the only record
    # that this repair ran.
    carts = Object.new
    carts.define_singleton_method(:update_items_prices) { |_token, _items| { "success" => true } }
    carts.define_singleton_method(:append_metadata) { |_token, _metadata| { "success" => true } }

    service = Callbacks::CartCountryChangedService.new(callback_params)

    assert_difference -> { CartPricingEvent.count }, 1 do
      FluidClient.stub(:new, ->(_token) { stub_client(carts) }) { service.call }
    end

    event = CartPricingEvent.order(:created_at).last
    assert_equal "country_changed", event.event_type
    assert event.preferred_pricing_applied
    assert_equal "PH", event.metadata["country_code"]
    assert_equal "US", event.metadata["previous_country_code"]
  end

  def test_refreshes_volumes_for_the_new_country_when_the_company_opts_in
    # CV/QV carry their own lock (update_volumes stamps cv_manually_updated), so
    # they stay under the old country unless this callback refreshes them too.
    company.create_integration_setting!(settings: { "adjust_volumes_for_subscription" => true })
    params = callback_params
    params["cart"]["items"] = [
      { "id" => 674137, "variant_id" => 10, "price" => "99.0", "subscription_price" => "2499.0",
        "quantity" => 1, "metadata" => LOCKED, },
    ]

    volume_calls = []
    carts = Object.new
    carts.define_singleton_method(:update_items_prices) { |_token, _items| { "success" => true } }
    carts.define_singleton_method(:append_metadata) { |_token, _metadata| { "success" => true } }
    carts.define_singleton_method(:update_item_volumes) do |_token, item_id, volumes|
      volume_calls << { item_id: item_id, volumes: volumes }
      { "success" => true }
    end

    variants = VolumeTestHelpers::FakeVariants.new(
      10 => [ { "country_code" => "PH", "cv" => 100, "qv" => 50,
                "price" => "3000.0", "subscription_price" => "2499.0", } ]
    )
    client = stub_client(carts)
    client.define_singleton_method(:variants) { variants }

    service = Callbacks::CartCountryChangedService.new(params)

    FluidClient.stub(:new, ->(_token) { client }) { service.call }

    assert_equal 1, volume_calls.size, "the corrected line needs its volumes refreshed too"
    assert_equal 674137, volume_calls.first[:item_id]
  end
  # --- CURRENT-3361 ---

  def test_does_not_repair_locked_lines_on_a_cart_that_is_already_captured
    # A country change on a paid cart is not something this droplet can act on:
    # the amount was already charged, so rewriting the lines only desyncs the
    # order from the capture.
    writes = []
    carts = Object.new
    carts.define_singleton_method(:update_items_prices) { |_token, items| writes << items }
    carts.define_singleton_method(:append_metadata) { |_token, metadata| writes << metadata }
    params = callback_params
    params["cart"]["state"] = "payment_captured"

    service = Callbacks::CartCountryChangedService.new(params)
    result = FluidClient.stub(:new, ->(_token) { stub_client(carts) }) { service.call }

    assert result[:success]
    assert_empty writes, "must not repair locked lines on a captured cart"
    assert_nil result[:metadata], "must not push a price_type back on the response channel"
  end

  def test_does_not_log_a_repair_event_for_a_cart_that_is_already_captured
    # The dashboard is the only record this repair ran, so logging one for a
    # reprice that was refused would be a lie.
    carts = Object.new
    carts.define_singleton_method(:update_items_prices) { |_token, _items| { "success" => true } }
    carts.define_singleton_method(:append_metadata) { |_token, _metadata| { "success" => true } }
    params = callback_params
    params["cart"]["state"] = "payment_captured"

    service = Callbacks::CartCountryChangedService.new(params)

    assert_no_difference -> { CartPricingEvent.count } do
      FluidClient.stub(:new, ->(_token) { stub_client(carts) }) { service.call }
    end
  end
end
