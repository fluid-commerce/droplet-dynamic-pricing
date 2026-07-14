require "test_helper"

class Callbacks::CustomerLoggedInServiceTest < ActiveSupport::TestCase
  include VolumeTestHelpers

  fixtures(:companies)

  test "applies subscription volumes for a preferred customer when company opts in" do
    company = companies(:acme)
    company.create_integration_setting!(settings: { "adjust_volumes_for_subscription" => true })
    cart = {
      "cart_token" => "ct_login",
      "country_code" => "US",
      "customer_id" => 888,
      "email" => "vip@example.com",
      "metadata" => { "price_type" => nil },
      "company" => { "id" => company.fluid_company_id },
      "items" => [
        { "id" => 1, "variant_id" => 10, "price" => "100.0", "subscription_price" => "90.0", "quantity" => 1 },
      ],
    }

    carts = VolumeTestHelpers::FakeCarts.new
    variants = VolumeTestHelpers::FakeVariants.new(10 => [ { "country_code" => "US", "cv" => 100, "qv" => 50,
"price" => "100.0", "subscription_price" => "90.0", } ])
    client = build_volume_client(carts: carts, variants: variants)

    service = Callbacks::CustomerLoggedInService.new({ cart: cart })
    service.define_singleton_method(:fluid_client) { client }

    service.stub(:is_preferred_customer?, true) do
      service.stub(:sync_pcc_metafield, nil) do
        service.call
      end
    end

    assert_equal 1, carts.volume_calls.size
    # ratio = (100-90)/100 = 0.1 -> 100*0.9 = 90, 50*0.9 = 45
    assert_equal({ "cv" => 90, "qv" => 45 }, carts.volume_calls.first[:volumes])
  end

  # STU2-2531: a live Fluid subscription makes the customer preferred even when
  # the customer_type metafield is not set — so login agrees with the
  # subscription-based rule item_added/item_updated use (no price oscillation).
  test "treats a customer with an active Fluid subscription as preferred even without the metafield" do
    company = companies(:acme)
    cart = {
      "cart_token" => "ct_login",
      "customer_id" => 888,
      "email" => "vip@example.com",
      "metadata" => { "price_type" => nil },
      "company" => { "id" => company.fluid_company_id },
      "items" => [ { "id" => 1, "price" => "100.0", "subscription_price" => "90.0", "quantity" => 1 } ],
    }

    carts = VolumeTestHelpers::FakeCarts.new
    variants = VolumeTestHelpers::FakeVariants.new({})
    client = build_volume_client(carts: carts, variants: variants)

    service = Callbacks::CustomerLoggedInService.new({ cart: cart })
    service.define_singleton_method(:fluid_client) { client }

    result = nil
    # metafield is NOT preferred, but the customer has a live Fluid subscription;
    # is_preferred_customer? itself is NOT stubbed, so its new active-subs branch runs.
    service.stub(:get_customer_type_from_metafields, nil) do
      service.stub(:has_active_subscriptions?, true) do
        service.stub(:sync_pcc_metafield, nil) do
          result = service.call
        end
      end
    end

    assert_equal true, result[:success]
    assert_equal({ "price_type" => Callbacks::BaseService::PREFERRED_CUSTOMER_TYPE }, result[:metadata])
    assert_equal 1, carts.metadata_calls.size, "expected the cart to be stamped preferred_customer"
    assert_equal 1, carts.items_prices_calls.size, "expected items to be repriced to subscription price"
  end
end
