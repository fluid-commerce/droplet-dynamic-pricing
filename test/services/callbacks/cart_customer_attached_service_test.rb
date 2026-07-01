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

    result = svc.stub(:is_preferred_customer?, true) do
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

    svc.stub(:is_preferred_customer?, false) { svc.call }

    assert_equal 0, carts.items_prices_calls.size
    assert_equal 0, carts.volume_calls.size
  end

  test "reverts to regular pricing and base volumes when not preferred but cart was preferred" do
    @company.create_integration_setting!(settings: { "adjust_volumes_for_subscription" => true })
    client, carts = client_and_carts
    svc = Callbacks::CartCustomerAttachedService.new({ cart: base_cart(price_type: "preferred_customer") })
    svc.define_singleton_method(:fluid_client) { client }

    svc.stub(:is_preferred_customer?, false) { svc.call }

    assert_nil carts.metadata_calls.first[:metadata]["price_type"]
    assert_equal({ "cv" => 100, "qv" => 50 }, carts.volume_calls.first[:volumes])
  end

  test "falls back to the customer payload email when the cart email is blank" do
    client, _carts = client_and_carts
    svc = Callbacks::CartCustomerAttachedService.new(
      { cart: base_cart(email: nil), customer: { "email" => "fromcustomer@example.com" } }
    )
    svc.define_singleton_method(:fluid_client) { client }

    seen = nil
    svc.stub(:is_preferred_customer?, ->(email) { seen = email; false }) { svc.call }

    assert_equal "fromcustomer@example.com", seen
  end
end
