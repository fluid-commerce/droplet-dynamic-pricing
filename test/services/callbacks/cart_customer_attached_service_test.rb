require "test_helper"

class Callbacks::CartCustomerAttachedServiceTest < ActiveSupport::TestCase
  include VolumeTestHelpers

  fixtures(:companies)

  def setup
    @company = companies(:acme)
  end

  def base_cart(price_type: nil, email: "vip@example.com")
    {
      "cart_token" => "ct_att",
      "country_code" => "US",
      "customer_id" => 888,
      "email" => email,
      "metadata" => { "price_type" => price_type },
      "company" => { "id" => @company.fluid_company_id },
      "items" => [
        { "id" => 1, "variant_id" => 10, "price" => "100.0", "subscription_price" => "90.0", "quantity" => 1 },
      ],
    }
  end

  def client_and_carts
    carts = VolumeTestHelpers::FakeCarts.new
    variants = VolumeTestHelpers::FakeVariants.new(
      10 => [ { "country_code" => "US", "cv" => 100, "qv" => 50, "price" => "100.0", "subscription_price" => "90.0" } ]
    )
    [ build_volume_client(carts: carts, variants: variants), carts ]
  end

  test "applies subscription pricing and volumes for a preferred customer" do
    @company.create_integration_setting!(settings: { "adjust_volumes_for_subscription" => true })
    client, carts = client_and_carts
    svc = Callbacks::CartCustomerAttachedService.new({ cart: base_cart })
    svc.define_singleton_method(:fluid_client) { client }

    result = svc.stub(:cart_qualifies_for_preferred_pricing?, true) do
      svc.stub(:sync_pcc_metafield, nil) { svc.call }
    end

    assert result[:success]
    assert_equal "preferred_customer", carts.metadata_calls.first[:metadata]["price_type"]
    assert_equal 1, carts.volume_calls.size
    assert_equal({ "cv" => 90, "qv" => 45 }, carts.volume_calls.first[:volumes])
  end

  test "does not touch pricing or volumes for a non-preferred customer" do
    @company.create_integration_setting!(settings: { "adjust_volumes_for_subscription" => true })
    client, carts = client_and_carts
    svc = Callbacks::CartCustomerAttachedService.new({ cart: base_cart(price_type: nil) })
    svc.define_singleton_method(:fluid_client) { client }

    svc.stub(:cart_qualifies_for_preferred_pricing?, false) { svc.call }

    assert_equal 0, carts.items_prices_calls.size
    assert_equal 0, carts.volume_calls.size
  end

  test "reverts to regular pricing and base volumes when not preferred but cart was preferred" do
    @company.create_integration_setting!(settings: { "adjust_volumes_for_subscription" => true })
    client, carts = client_and_carts
    svc = Callbacks::CartCustomerAttachedService.new({ cart: base_cart(price_type: "preferred_customer") })
    svc.define_singleton_method(:fluid_client) { client }

    svc.stub(:cart_qualifies_for_preferred_pricing?, false) { svc.call }

    assert_nil carts.metadata_calls.first[:metadata]["price_type"]
    assert_equal({ "cv" => 100, "qv" => 50 }, carts.volume_calls.first[:volumes])
  end

  test "falls back to the customer payload email when the cart email is blank" do
    # Still load-bearing: the Exigo half of the pricing rule keys off this email.
    svc = Callbacks::CartCustomerAttachedService.new(
      { cart: base_cart(email: nil), customer: { "email" => "fromcustomer@example.com" } }
    )

    assert_equal "fromcustomer@example.com", svc.send(:customer_email)
  end
  # --- CURRENT-3361 ---

  test "does not touch a cart when the callback was triggered by order completion" do
    # Incident callback #3: cart_customer_attached fired with trigger_source
    # "order_completion" on a payment_captured cart and repriced every line to
    # subscription prices 1s after the card was charged.
    @company.create_integration_setting!(settings: { "adjust_volumes_for_subscription" => true })
    client, carts = client_and_carts
    cart = base_cart.merge("state" => "payment_captured")
    svc = Callbacks::CartCustomerAttachedService.new(
      { cart: cart, context: { "trigger_source" => "order_completion" } }
    )
    svc.define_singleton_method(:fluid_client) { client }

    result = svc.stub(:cart_qualifies_for_preferred_pricing?, true) do
      svc.stub(:sync_pcc_metafield, nil) { svc.call }
    end

    assert result[:success]
    assert_nil result[:metadata], "must not push a price_type back on the response channel either"
    assert_equal 0, carts.items_prices_calls.size, "must not reprice a completed order"
    assert_equal 0, carts.metadata_calls.size, "must not restamp a completed order"
    assert_equal 0, carts.volume_calls.size, "must not rewrite volumes on a completed order"
  end
  test "still syncs the customer_type metafield on a settled cart" do
    # The metafield is a CUSTOMER resource, not a cart one: the settled-cart guard
    # does not protect it, and order_completion is ~39% of attaches, so gating it
    # would delay the stamp on most guest orders (CURRENT-3361).
    client, carts = client_and_carts
    cart = base_cart.merge("state" => "payment_captured")
    svc = Callbacks::CartCustomerAttachedService.new(
      { cart: cart, context: { "trigger_source" => "order_completion" } }
    )
    svc.define_singleton_method(:fluid_client) { client }

    synced = []
    svc.define_singleton_method(:sync_pcc_metafield) { |id| synced << id }

    result = svc.stub(:cart_qualifies_for_preferred_pricing?, true) { svc.call }

    assert result[:success]
    assert_equal [ 888 ], synced, "the customer metafield must still be stamped"
    assert_equal 0, carts.items_prices_calls.size, "but nothing cart-level may be written"
    assert_equal 0, carts.metadata_calls.size
    assert_nil result[:metadata]
  end
end
