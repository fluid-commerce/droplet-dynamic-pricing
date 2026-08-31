require "test_helper"

# The login path reads the customer_type metafield, and then writes it. Both
# halves had a defect: the read happened twice for the same customer, and the
# write's fallback could not succeed.
class Callbacks::PccMetafieldTest < ActiveSupport::TestCase
  fixtures(:companies)

  def setup
    @company = companies(:acme)
    @cart_data = {
      "id" => 265327,
      "cart_token" => "ct_pcc",
      "customer_id" => 12345,
      "email" => "shopper@example.com",
      "country_code" => "US",
      "metadata" => {},
      "company" => { "id" => @company.fluid_company_id, "name" => @company.name },
      "items" => [],
    }
  end

  # Reports "retail", so is_preferred_customer? falls through to the live
  # subscription lookup — which says preferred, and that is the combination that
  # goes on to call sync_pcc_metafield and read the metafield a second time.
  def build_client(reads:, definition_error: nil, created: nil, updated: nil)
    metafields = Object.new
    metafields.define_singleton_method(:get_by_key) do |**|
      reads << :read
      { "value" => { "customer_type" => "retail" } }
    end
    metafields.define_singleton_method(:ensure_definition) do |**|
      raise definition_error if definition_error

      { "id" => 1 }
    end
    metafields.define_singleton_method(:update) do |**kwargs|
      updated&.push(kwargs)
      raise FluidClient::ResourceNotFoundError, "Resource not found: 404" if definition_error.nil? && created

      { "id" => 1 }
    end
    metafields.define_singleton_method(:create) { |**kwargs| created&.push(kwargs); { "id" => 1 } }

    subscriptions = Object.new
    subscriptions.define_singleton_method(:get_by_customer) { |_id, **| { "subscriptions" => [ { "id" => 1 } ] } }

    carts = Object.new
    carts.define_singleton_method(:append_metadata) { |_token, _metadata| { "success" => true } }
    carts.define_singleton_method(:update_items_prices) { |_token, _items| { "success" => true } }

    client = Object.new
    client.define_singleton_method(:metafields) { metafields }
    client.define_singleton_method(:subscriptions) { subscriptions }
    client.define_singleton_method(:carts) { carts }
    client
  end

  def call_logged_in(client)
    FluidClient.stub(:new, ->(_token, **) { client }) do
      Callbacks::CustomerLoggedInService.new({ cart: @cart_data }).call
    end
  end

  test "reads the customer_type metafield once per request, not once per reader" do
    reads = []

    result = call_logged_in(build_client(reads: reads))

    assert result[:success]
    assert_equal 1, reads.size, "is_preferred_customer? and sync_pcc_metafield should share one read"
  end

  # ensure_definition re-raises a 404 from find_definition_by_key. The rescue
  # then reached `create` with json_value still nil, and `value cannot be blank`
  # made the fallback impossible.
  test "the create fallback carries a value when the definition lookup 404s" do
    created = []
    client = build_client(
      reads: [],
      definition_error: FluidClient::ResourceNotFoundError.new("Resource not found: 404"),
      created: created
    )

    result = call_logged_in(client)

    assert result[:success]
    assert_equal 1, created.size, "the 404 should fall through to create"
    assert_equal({ "customer_type" => "preferred_customer" }, created.first[:value])
  end
  # A failed read is not an answer, so it must not go in the memo: the second
  # reader has to re-attempt rather than take the nil as "retail" and spend Fluid
  # writes correcting something it never saw.
  test "a failed metafield read stays retryable within the request" do
    reads = []
    metafields = Object.new
    metafields.define_singleton_method(:get_by_key) do |**|
      reads << :read
      raise FluidClient::TimeoutError, "boom" if reads.size == 1

      { "value" => { "customer_type" => "retail" } }
    end
    metafields.define_singleton_method(:ensure_definition) { |**| { "id" => 1 } }
    metafields.define_singleton_method(:update) { |**| { "id" => 1 } }

    subscriptions = Object.new
    subscriptions.define_singleton_method(:get_by_customer) { |_id, **| { "subscriptions" => [ { "id" => 1 } ] } }

    carts = Object.new
    carts.define_singleton_method(:append_metadata) { |_token, _metadata| { "success" => true } }
    carts.define_singleton_method(:update_items_prices) { |_token, _items| { "success" => true } }

    client = Object.new
    client.define_singleton_method(:metafields) { metafields }
    client.define_singleton_method(:subscriptions) { subscriptions }
    client.define_singleton_method(:carts) { carts }

    result = call_logged_in(client)

    assert result[:success]
    assert_equal 2, reads.size, "the failed read must not be memoized"
  end
end
