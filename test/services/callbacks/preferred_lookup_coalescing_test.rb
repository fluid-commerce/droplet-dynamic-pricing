require "test_helper"

# Core fires one cart_item callback per line, so an N-line add runs these
# services N times within a few seconds. What each run must NOT do is re-ask the
# external systems the same question about the same customer.
class Callbacks::PreferredLookupCoalescingTest < ActiveSupport::TestCase
  fixtures(:companies)

  def setup
    @company = companies(:acme)
    # No subscription line and no price_type stamp, so the free in-cart check
    # cannot short-circuit and the external lookups actually run.
    @cart_data = {
      "id" => 265327,
      "cart_token" => "ct_coalesce",
      "customer_id" => 12345,
      "email" => "Shopper@Example.com",
      "country_code" => "US",
      "metadata" => {},
      "company" => { "id" => @company.fluid_company_id, "name" => @company.name },
      "items" => [ { "id" => 674137, "price" => "80.0", "subscription_price" => "72.0" } ],
    }
    @cart_item = { "id" => 674139, "price" => "100.0", "subscription_price" => "90.0" }
  end

  def with_cache
    previous = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    yield
  ensure
    Rails.cache = previous
  end

  def carts_resource
    carts = Object.new
    carts.define_singleton_method(:update_items_prices) { |_token, _items| { "success" => true } }
    carts.define_singleton_method(:append_metadata) { |_token, _metadata| { "success" => true } }
    carts.define_singleton_method(:update_item_volumes) { |_token, _item, _volumes| { "success" => true } }
    carts
  end

  # Counts how many times the Fluid subscriptions lookup is asked.
  def client_counting_subscriptions(calls, raise_with: nil)
    subscriptions = Object.new
    subscriptions.define_singleton_method(:get_by_customer) do |customer_id, **|
      calls << customer_id
      raise raise_with if raise_with

      { "subscriptions" => [ { "id" => 1 } ] }
    end

    client = Object.new
    carts = carts_resource
    client.define_singleton_method(:subscriptions) { subscriptions }
    client.define_singleton_method(:carts) { carts }
    client
  end

  def run_item_added(client)
    Callbacks::CartItemAddedService
      .new({ cart: @cart_data, cart_item: @cart_item })
      .call
  end

  test "a second callback for the same customer does not re-ask Fluid" do
    calls = []

    with_cache do
      FluidClient.stub(:new, ->(_token, **) { client_counting_subscriptions(calls) }) do
        run_item_added(nil)
        run_item_added(nil)
      end
    end

    assert_equal 1, calls.size, "the subscriptions lookup should be asked once per burst, not per line"
  end

  test "a cached negative answer is honoured rather than re-asked" do
    calls = []
    subscriptions = Object.new
    subscriptions.define_singleton_method(:get_by_customer) do |customer_id, **|
      calls << customer_id
      { "subscriptions" => [] }
    end
    client = Object.new
    carts = carts_resource
    client.define_singleton_method(:subscriptions) { subscriptions }
    client.define_singleton_method(:carts) { carts }

    with_cache do
      FluidClient.stub(:new, ->(_token, **) { client }) do
        run_item_added(nil)
        run_item_added(nil)
      end
    end

    # false is a real answer; only nil means "nothing cached".
    assert_equal 1, calls.size, "a cached false must not read as a cache miss"
  end

  # The safety property. A failed lookup means "unknown", and the rollback paths
  # treat unknown differently from "not preferred" (CURRENT-3361) — so a blip must
  # never be frozen into the cache for the whole window.
  test "a failed lookup is not cached, so the next callback retries" do
    calls = []

    with_cache do
      FluidClient.stub(:new, ->(_token, **) {
        client_counting_subscriptions(calls, raise_with: FluidClient::TimeoutError.new("boom"))
      }) do
        run_item_added(nil)
        run_item_added(nil)
      end
    end

    assert_equal 2, calls.size, "a failure must stay uncached"
  end

  test "the cache key separates companies asking about the same customer" do
    service = Callbacks::CartItemAddedService.new({ cart: @cart_data, cart_item: @cart_item })
    other = Callbacks::CartItemAddedService.new(
      { cart: @cart_data.merge("company" => { "id" => companies(:globex).fluid_company_id }),
        cart_item: @cart_item, }
    )

    mine = service.send(:preferred_lookup_key, :fluid_subscriptions, 12345)
    theirs = other.send(:preferred_lookup_key, :fluid_subscriptions, 12345)

    refute_nil mine
    refute_equal mine, theirs
  end

  test "the cache key does not carry the raw email" do
    service = Callbacks::CartItemAddedService.new({ cart: @cart_data, cart_item: @cart_item })

    key = service.send(:preferred_lookup_key, :exigo_autoship, "Shopper@Example.com")

    refute_includes key, "Shopper@Example.com"
    refute_includes key.downcase, "shopper@example.com"
  end

  test "the cache key ignores case and padding on the identifier" do
    service = Callbacks::CartItemAddedService.new({ cart: @cart_data, cart_item: @cart_item })

    assert_equal service.send(:preferred_lookup_key, :exigo_autoship, "Shopper@Example.com"),
                 service.send(:preferred_lookup_key, :exigo_autoship, "  shopper@example.com ")
  end

  test "caching is skipped rather than mis-keyed when the company is unknown" do
    service = Callbacks::CartItemAddedService.new(
      { cart: @cart_data.merge("company" => nil), cart_item: @cart_item }
    )

    assert_nil service.send(:preferred_lookup_key, :fluid_subscriptions, 12345)
  end

  # Cache trouble must never be the thing that breaks pricing.
  test "a cache read failure falls through to the live lookup" do
    calls = []
    broken = Object.new
    broken.define_singleton_method(:read) { |_key| raise "cache down" }
    broken.define_singleton_method(:write) { |*| raise "cache down" }

    previous = Rails.cache
    Rails.cache = broken
    begin
      FluidClient.stub(:new, ->(_token, **) { client_counting_subscriptions(calls) }) do
        result = run_item_added(nil)

        assert result[:success]
      end
    ensure
      Rails.cache = previous
    end

    assert_equal 1, calls.size
  end
end
