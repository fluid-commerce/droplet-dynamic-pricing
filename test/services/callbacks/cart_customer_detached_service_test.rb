require "test_helper"

class Callbacks::CartCustomerDetachedServiceTest < ActiveSupport::TestCase
  include VolumeTestHelpers

  fixtures(:companies)

  def setup
    @company = companies(:acme)
  end

  def detached_cart(items:, price_type: "preferred_customer")
    {
      "cart_token" => "ct_det",
      "country_code" => "US",
      "metadata" => { "price_type" => price_type },
      "company" => { "id" => @company.fluid_company_id },
      "items" => items,
      "context" => { "trigger_source" => "logout", "previous_customer_id" => 888 },
    }
  end

  def client_and_carts
    carts = VolumeTestHelpers::FakeCarts.new
    variants = VolumeTestHelpers::FakeVariants.new(
      10 => [ { "country_code" => "US", "cv" => 100, "qv" => 50, "price" => "100.0", "subscription_price" => "90.0" } ]
    )
    [ build_volume_client(carts: carts, variants: variants), carts ]
  end

  test "reverts to regular pricing and base volumes when no subscription remains" do
    @company.create_integration_setting!(settings: { "adjust_volumes_for_subscription" => true })
    client, carts = client_and_carts
    items = [ { "id" => 1, "variant_id" => 10, "price" => "100.0", "quantity" => 1 } ]
    svc = Callbacks::CartCustomerDetachedService.new({ cart: detached_cart(items: items) })
    svc.define_singleton_method(:fluid_client) { client }

    result = svc.call

    assert result[:success]
    assert_nil carts.metadata_calls.first[:metadata]["price_type"]
    assert_equal({ "cv" => 100, "qv" => 50 }, carts.volume_calls.first[:volumes])
  end

  test "keeps subscription pricing and volumes when a subscription item remains in the cart" do
    @company.create_integration_setting!(settings: { "adjust_volumes_for_subscription" => true })
    client, carts = client_and_carts
    items = [ {
      "id" => 1, "variant_id" => 10, "price" => "100.0",
      "subscription_price" => "90.0", "quantity" => 1, "subscription" => true,
    } ]
    svc = Callbacks::CartCustomerDetachedService.new({ cart: detached_cart(items: items) })
    svc.define_singleton_method(:fluid_client) { client }

    svc.call

    assert_equal "preferred_customer", carts.metadata_calls.first[:metadata]["price_type"]
    assert_equal({ "cv" => 90, "qv" => 45 }, carts.volume_calls.first[:volumes])
  end

  test "reverts prices but does not touch volumes when the volume toggle is off" do
    client, carts = client_and_carts
    items = [ { "id" => 1, "variant_id" => 10, "price" => "100.0", "quantity" => 1 } ]
    svc = Callbacks::CartCustomerDetachedService.new({ cart: detached_cart(items: items) })
    svc.define_singleton_method(:fluid_client) { client }

    svc.call

    assert_equal 1, carts.items_prices_calls.size
    assert_equal 0, carts.volume_calls.size
  end
end
