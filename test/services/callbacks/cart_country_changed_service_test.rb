require "test_helper"

class Callbacks::CartCountryChangedServiceTest < ActiveSupport::TestCase
  include VolumeTestHelpers

  fixtures(:companies)

  def company
    companies(:acme)
  end

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
        { "id" => 674137, "price" => "99.0",  "subscription_price" => "2499.0" },
        { "id" => 674138, "price" => "113.85", "subscription_price" => "1999.0" },
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

  def test_leaves_a_cart_that_was_never_preferred_alone
    # Never preferred means this droplet never locked a line here, so core's own
    # reprice is already right and writing would lock a price Fluid set itself.
    carts = Object.new
    carts.define_singleton_method(:update_items_prices) { |_token, _items| flunk "must not reprice a retail cart" }
    carts.define_singleton_method(:append_metadata) { |_token, _metadata| flunk "must not stamp a retail cart" }

    service = Callbacks::CartCountryChangedService.new(callback_params(price_type: "retail"))

    result = FluidClient.stub(:new, ->(_token) { stub_client(carts) }) { service.call }

    assert result[:success]
    assert_equal "Cart does not have preferred_customer pricing", result[:message]
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
      { "id" => 674137, "variant_id" => 10, "price" => "99.0", "subscription_price" => "2499.0", "quantity" => 1 },
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
end
