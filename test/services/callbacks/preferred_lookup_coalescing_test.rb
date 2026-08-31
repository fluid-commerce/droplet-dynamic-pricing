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

  # Deliberately NOT normalised. Exigo receives the raw string in
  # `WHERE c.Email = ?`, where whitespace is significant and the collation may be
  # case-sensitive, so two identifiers that can get different answers must not
  # share one cached result.
  test "the cache key tracks the identifier verbatim" do
    service = Callbacks::CartItemAddedService.new({ cart: @cart_data, cart_item: @cart_item })

    refute_equal service.send(:preferred_lookup_key, :exigo_autoship, "Shopper@Example.com"),
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
  # A 200 whose body lacks the key we read cannot be told apart from "no
  # subscriptions", and false is the value that unlocks the strip branch. It is
  # returned as today, but must not be spread across the customer's other carts.
  test "a 200 with no subscriptions key is answered but not cached" do
    calls = []
    subscriptions = Object.new
    subscriptions.define_singleton_method(:get_by_customer) do |customer_id, **|
      calls << customer_id
      {}
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

    assert_equal 2, calls.size, "an unusable body must not be cached as a hard false"
  end

  # order_completion fires while a subscription-start order is being finalised, so
  # the answer taken there is the one most likely to be about to flip. Reads still
  # hit the cache; only the write is skipped. Routed through
  # CustomerLoggedInService because it is the one service that runs the lookup
  # ABOVE its cart_settled? guard, deliberately.
  test "an answer taken as the order completes is not frozen into the cache" do
    calls = []
    metafields = Object.new
    metafields.define_singleton_method(:get_by_key) { |**| { "value" => { "customer_type" => "retail" } } }
    metafields.define_singleton_method(:ensure_definition) { |**| { "id" => 1 } }
    metafields.define_singleton_method(:update) { |**| { "id" => 1 } }
    subscriptions = Object.new
    subscriptions.define_singleton_method(:get_by_customer) do |customer_id, **|
      calls << customer_id
      { "subscriptions" => [] }
    end
    client = Object.new
    carts = carts_resource
    client.define_singleton_method(:subscriptions) { subscriptions }
    client.define_singleton_method(:metafields) { metafields }
    client.define_singleton_method(:carts) { carts }

    params = {
      cart: @cart_data.merge("state" => "payment_captured"),
      context: { "trigger_source" => "order_completion" },
    }

    with_cache do
      FluidClient.stub(:new, ->(_token, **) { client }) do
        Callbacks::CustomerLoggedInService.new(params).call
        Callbacks::CustomerLoggedInService.new(params).call
      end
    end

    assert_equal 2, calls.size, "the order_completion answer must not be cached"
  end

  # The operational lever: set the env to 0 and caching is off at once, reads
  # included, without shipping code.
  # The operational lever: set the env to 0 and caching is off at once, reads
  # included, without shipping code. Written first with the switch OFF so there is
  # a live entry to refuse — otherwise the write guard alone would carry the test.
  test "a zero TTL stops serving entries already in the cache" do
    calls = []

    with_cache do
      FluidClient.stub(:new, ->(_token, **) { client_counting_subscriptions(calls) }) do
        run_item_added(nil)
        assert_equal 1, calls.size, "the first run should populate the cache"

        with_ttl(0) { run_item_added(nil) }
      end
    end

    assert_equal 2, calls.size, "TTL=0 has to stop serving, not just stop writing"
  end

  def with_ttl(seconds)
    previous = Callbacks::BaseService::PREFERRED_LOOKUP_TTL
    Callbacks::BaseService.send(:remove_const, :PREFERRED_LOOKUP_TTL)
    Callbacks::BaseService.const_set(:PREFERRED_LOOKUP_TTL, seconds)
    yield
  ensure
    Callbacks::BaseService.send(:remove_const, :PREFERRED_LOOKUP_TTL)
    Callbacks::BaseService.const_set(:PREFERRED_LOOKUP_TTL, previous)
  end
end
