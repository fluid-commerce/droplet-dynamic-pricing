require "test_helper"

# One rule, every callback (CURRENT-3361).
#
# The oscillation had a single cause: three different answers to "does this cart
# get preferred pricing?". is_preferred_customer? asked the customer_type
# metafield, cart_qualifies_for_preferred_pricing? asked the cart plus live
# subscriptions, and the rollback paths asked only whether a subscription line
# remained. On cart ct_3ALdBgWkp8cMRUdai6J0EJ, cart_subscription_removed answered
# retail from the cart and cart_customer_attached answered preferred from a stale
# metafield ten minutes later.
#
# The rule: preferred iff the cart carries a subscription line, or the customer
# holds an active subscription (Fluid) or autoship (Exigo) — derived live on every
# callback, never read back from the cart stamp or the customer_type metafield.
#
# Out of scope on purpose: the Exigo lookup keys off the cart's email and so still
# fires on a guest cart. That predates this work and nobody has reported it, so
# unifying the rule keeps it rather than quietly changing what Rain and Yoli
# charge guests.
class Callbacks::PreferredPricingRuleTest < ActiveSupport::TestCase
  include VolumeTestHelpers

  fixtures(:companies)

  REGULAR      = "61.0".freeze
  SUBSCRIPTION = "55.0".freeze

  # Services that decide the price of a whole cart or of the item they carry.
  DECIDERS = %w[
    cart_item_added
    cart_item_updated
    customer_logged_in
    cart_customer_attached
    cart_customer_detached
    subscription_removed
    verify_email_success
  ].freeze

  def setup
    @company = companies(:acme)
  end

  # --- the rule itself ------------------------------------------------------

  test "a bound customer with an Exigo autoship is preferred" do
    svc = service(logged_in: true, exigo: true)

    assert svc.send(:cart_qualifies_for_preferred_pricing?)
  end

  test "a bound customer with an active Fluid subscription is preferred" do
    svc = service(logged_in: true, active_sub: true)

    assert svc.send(:cart_qualifies_for_preferred_pricing?)
  end

  test "the stale customer_type metafield alone does not make a cart preferred" do
    svc = service(logged_in: true, metafield: "preferred_customer")

    refute svc.send(:cart_qualifies_for_preferred_pricing?),
      "nothing outside the Exigo-only sync ever demotes that metafield"
  end

  test "a subscription line in the cart is preferred even without a bound customer" do
    svc = service(logged_in: false, sub_line: true)

    assert svc.send(:cart_qualifies_for_preferred_pricing?),
      "a line in the cart is a fact about the cart, not a guess about the shopper"
  end

  # --- the anti-oscillation invariant --------------------------------------

  test "every callback writes the same price on a cart with a subscription line" do
    assert_single_price(SUBSCRIPTION, logged_in: true, sub_line: true)
  end

  test "every callback writes the same price for a bound subscriber" do
    assert_single_price(SUBSCRIPTION, logged_in: true, active_sub: true)
  end

  test "every callback writes the same price for a lapsed subscriber with a stale metafield" do
    # The leak: metafield says preferred, nothing else does.
    assert_single_price(REGULAR, logged_in: true, metafield: "preferred_customer",
                                 stamp: "preferred_customer")
  end

private

  # Runs every deciding callback over one cart and asserts they all landed on the
  # same price. Disagreement here IS the oscillation, whichever value is right.
  def assert_single_price(expected, **opts)
    seen = {}
    DECIDERS.each do |name|
      carts = VolumeTestHelpers::FakeCarts.new
      svc = service(name: name, carts: carts, **opts)
      svc.call
      prices = carts.items_prices_calls.flat_map { |c| c[:items].map { |i| i["price"].to_s } }
      seen[name] = prices.uniq unless prices.empty?
    end

    disagreeing = seen.reject { |_, prices| prices == [ expected ] }
    assert_empty disagreeing,
      "callbacks disagreed (expected all #{expected}): #{seen.inspect}"
  end

  def service(name: "cart_item_added", carts: nil, logged_in: true, sub_line: false,
              metafield: nil, active_sub: false, exigo: false, stamp: nil)
    carts ||= VolumeTestHelpers::FakeCarts.new
    cart = {
      "cart_token" => "ct_rule",
      "state" => "start",
      "country_code" => "US",
      "email" => "shopper@example.com",
      "customer_id" => (888 if logged_in),
      "metadata" => { "price_type" => stamp },
      "company" => { "id" => @company.fluid_company_id },
      "items" => [ {
        "id" => 1,
        "variant_id" => 10,
        "price" => REGULAR,
        "subscription_price" => SUBSCRIPTION,
        "product" => { "price" => REGULAR },
        "quantity" => 1,
        "subscription" => sub_line,
        "metadata" => { "price_locked" => true },
      } ],
    }
    params = { cart: cart, context: { "trigger_source" => "checkout_entry" } }
    params[:cart_item] = cart["items"].first
    params[:customer] = { "id" => 888, "email" => "shopper@example.com" }

    klass = "Callbacks::#{name.camelize}Service".constantize
    svc = klass.new(params.with_indifferent_access)
    client = RuleClient.new(carts: carts, metafield: metafield, active_sub: active_sub)
    svc.define_singleton_method(:fluid_client) { client }
    svc.define_singleton_method(:exigo_integration_enabled?) { exigo }
    svc.define_singleton_method(:exigo_client) { ExigoAutoship.new(exigo) }
    svc
  end

  class ExigoAutoship
    def initialize(active) = @active = active
    def customer_has_active_autoship_by_email?(_email) = @active
  end

  class RuleClient
    def initialize(carts:, metafield:, active_sub:)
      @carts = carts
      @metafield = metafield
      @active_sub = active_sub
    end

    def carts = @carts

    def variants
      @variants ||= VolumeTestHelpers::FakeVariants.new(
        10 => [ { "country_code" => "US", "cv" => 100, "qv" => 50,
                  "price" => "61.0", "subscription_price" => "55.0", } ]
      )
    end

    def subscriptions
      active = @active_sub
      Object.new.tap do |o|
        o.define_singleton_method(:get_by_customer) do |_id, **_opts|
          { "subscriptions" => active ? [ { "id" => 1 } ] : [] }
        end
      end
    end

    def metafields
      value = @metafield
      Object.new.tap do |o|
        o.define_singleton_method(:get_by_key) do |**|
          value && { "key" => "customer_type", "value" => { "customer_type" => value } }
        end
        o.define_singleton_method(:ensure_definition) { |**| { "success" => true } }
        o.define_singleton_method(:update) { |**| { "success" => true } }
        o.define_singleton_method(:create) { |**| { "success" => true } }
      end
    end

    def customers
      Object.new.tap do |o|
        o.define_singleton_method(:get) { |**|
 { "customers" => [ { "id" => 888, "email" => "shopper@example.com" } ] } }
      end
    end

    def blank? = false
  end

  # --- logout leaves no bound customer ---------------------------------------

  test "a logged-out cart with no subscription line goes back to retail" do
    # The customer who left was a real subscriber, but they are gone: nothing is
    # bound to this cart any more, so only a line in it could justify preferred.
    [ false, true ].each do |exigo_enabled|
      carts = VolumeTestHelpers::FakeCarts.new
      svc = service(name: "cart_customer_detached", carts: carts, logged_in: false,
                    sub_line: false, active_sub: true, exigo: exigo_enabled,
                    metafield: "preferred_customer", stamp: "preferred_customer")
      svc.call

      prices = carts.items_prices_calls.flat_map { |c| c[:items].map { |i| i["price"].to_s } }
      assert_equal [ REGULAR ], prices.uniq,
        "logout must revert to retail (exigo_enabled=#{exigo_enabled})"
      assert_nil carts.metadata_calls.last[:metadata]["price_type"]
    end
  end

  test "a logged-out cart keeps preferred while a subscription line remains in it" do
    carts = VolumeTestHelpers::FakeCarts.new
    svc = service(name: "cart_customer_detached", carts: carts, logged_in: false,
                  sub_line: true, stamp: "preferred_customer")
    svc.call

    prices = carts.items_prices_calls.flat_map { |c| c[:items].map { |i| i["price"].to_s } }
    assert_equal [ SUBSCRIPTION ], prices.uniq
  end
end
