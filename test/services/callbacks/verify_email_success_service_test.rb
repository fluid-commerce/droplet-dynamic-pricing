require "test_helper"

class Callbacks::VerifyEmailSuccessServiceTest < ActiveSupport::TestCase
  fixtures(:companies)

  TEST_PREFERRED_TYPE = "preferred_customer"

  def test_returns_failure_when_email_is_missing_in_cart
    company = companies(:acme)
    cart_payload = build_cart_payload(company: company, cart_token: "ct_123", email: nil)
    params = { cart: cart_payload }

    result = Callbacks::VerifyEmailSuccessService.call(params)

    assert_equal false, result[:success]
    assert_equal "Missing email", result[:message]
  end

  def test_reverts_a_stamped_cart_that_no_longer_qualifies
    company = companies(:acme)
    email = "unknown@example.com"
    cart_token = "ct_123"
    cart_payload = build_cart_payload(
      company: company,
      cart_token: cart_token,
      email: email,
      items: [ { "id" => 1, "price" => "100.0" } ],
      metadata: { "price_type" => "preferred_customer" }
    )
    params = { cart: cart_payload }

    fake_client = stubbed_fluid_client(customers_response: [])

    service = Callbacks::VerifyEmailSuccessService.new(params)
    service.define_singleton_method(:fluid_client) { fake_client }

    result = service.call

    assert_equal true, result[:success], "Falló con error: #{result[:error]}"
    expected_updates = [
      [ cart_token, { "price_type" => nil } ],
    ]
    assert_equal expected_updates, fake_client.metadata_updates
    assert_equal 1, fake_client.items_prices_updates.size
  end

  def test_keeps_preferred_pricing_when_subscription_in_cart
    company = companies(:acme)
    email = "unknown@example.com"
    cart_token = "ct_123"
    cart_payload = build_cart_payload(
      company: company,
      cart_token: cart_token,
      email: email,
      items: [ { "id" => 1, "price" => "100.0", "subscription" => true } ],
      metadata: { "price_type" => "preferred_customer" }
    )
    params = { cart: cart_payload }

    fake_client = stubbed_fluid_client(customers_response: [])

    service = Callbacks::VerifyEmailSuccessService.new(params)
    service.define_singleton_method(:fluid_client) { fake_client }

    result = service.call

    assert_equal true, result[:success]
    # A subscription line still qualifies the cart, so preferred pricing survives —
    # and is now re-affirmed rather than left implicit, so the stamp and the line
    # prices cannot drift apart (CURRENT-3361).
    assert_equal [ [ cart_token, { "price_type" => "preferred_customer" } ] ],
      fake_client.metadata_updates
    assert_equal 1, fake_client.items_prices_updates.size
  end

  def test_keeps_preferred_pricing_when_logged_in_with_subscription_in_cart
    company = companies(:acme)
    email = "unknown@example.com"
    cart_token = "ct_123"
    cart_payload = build_cart_payload(
      company: company,
      cart_token: cart_token,
      email: email,
      customer_id: 123,
      items: [ { "id" => 1, "price" => "100.0", "subscription" => true } ],
      metadata: { "price_type" => "preferred_customer" }
    )
    params = { cart: cart_payload }

    fake_client = stubbed_fluid_client(customers_response: [])

    service = Callbacks::VerifyEmailSuccessService.new(params)
    service.define_singleton_method(:fluid_client) { fake_client }

    result = service.call

    assert_equal true, result[:success]
    # A subscription line still qualifies the cart, so preferred pricing survives —
    # and is now re-affirmed rather than left implicit, so the stamp and the line
    # prices cannot drift apart (CURRENT-3361).
    assert_equal [ [ cart_token, { "price_type" => "preferred_customer" } ] ],
      fake_client.metadata_updates
    assert_equal 1, fake_client.items_prices_updates.size
  end

  def test_leaves_an_unstamped_cart_alone_when_it_does_not_qualify
    company = companies(:acme)
    target_email = "john@example.com"
    similar_email = "john.doe@example.com"

    cart_payload = build_cart_payload(company: company, cart_token: "ct_123", email: target_email)
    params = { cart: cart_payload }

    customer_response = [ { "id" => 1, "email" => similar_email } ]
    fake_client = stubbed_fluid_client(customers_response: customer_response)

    service = Callbacks::VerifyEmailSuccessService.new(params)
    service.define_singleton_method(:fluid_client) { fake_client }

    result = service.call

    assert_equal true, result[:success]
    # An unstamped cart that does not qualify is left alone, not rewritten.
    assert_empty fake_client.metadata_updates
    assert_empty fake_client.items_prices_updates
  end

  def test_does_not_write_when_the_customer_cannot_be_identified
    company = companies(:acme)
    email = "test@example.com"
    cart_payload = build_cart_payload(company: company, cart_token: "ct_123", email: email)
    params = { cart: cart_payload }

    customer_response = [ { "email" => email, "id" => nil } ]
    fake_client = stubbed_fluid_client(customers_response: customer_response)

    service = Callbacks::VerifyEmailSuccessService.new(params)
    service.define_singleton_method(:fluid_client) { fake_client }

    result = service.call
    assert_equal true, result[:success]
    assert_empty fake_client.metadata_updates
  end

  def test_does_not_write_on_the_strength_of_a_missing_metafield
    company = companies(:acme)
    email = "test@example.com"
    cart_payload = build_cart_payload(company: company, cart_token: "ct_123", email: email)
    params = { cart: cart_payload }

    customer_response = [ { "id" => 999, "email" => email } ]
    fake_client = stubbed_fluid_client(
      customers_response: customer_response,
      customer_type_metafield: nil
    )

    service = Callbacks::VerifyEmailSuccessService.new(params)
    service.define_singleton_method(:fluid_client) { fake_client }

    result = service.call
    assert_equal true, result[:success]
    # The customer_type metafield no longer decides anything either way.
    assert_empty fake_client.metadata_updates
  end

  def test_updates_cart_metadata_when_customer_is_preferred_and_logged_in
    company = companies(:acme)
    email = "vip@example.com"
    cart_token = "ct_vip_123"
    cart_payload = build_cart_payload(
      company: company,
      cart_token: cart_token,
      email: email,
      customer_id: 888,
      items: [ { "id" => 1, "price" => "100.0", "subscription_price" => "90.0" } ],
      metadata: { "price_type" => "preferred_customer" }
    )
    params = { cart: cart_payload }

    customer_response = [ { "id" => 888, "email" => email } ]

    metafield = {
      "key" => "customer_type",
      "value" => { "customer_type" => TEST_PREFERRED_TYPE },
    }

    fake_client = stubbed_fluid_client(
      customers_response: customer_response,
      customer_type_metafield: metafield,
      active_subscriptions: [ { "id" => 1, "status" => "active" } ]
    )

    service = Callbacks::VerifyEmailSuccessService.new(params)
    service.define_singleton_method(:fluid_client) { fake_client }

    result = service.call

    assert_equal true, result[:success]
    # One decision, one write. This used to clean to regular and then re-apply
    # preferred in the same request, because the two halves consulted different
    # sources (CURRENT-3361).
    assert_equal [ [ cart_token, { "price_type" => TEST_PREFERRED_TYPE } ] ],
      fake_client.metadata_updates
    assert_equal 1, fake_client.items_prices_updates.size
  end

  def test_applies_subscription_volumes_when_preferred_and_company_opts_in
    company = companies(:acme)
    company.create_integration_setting!(settings: { "adjust_volumes_for_subscription" => true })
    email = "vip@example.com"
    cart_token = "ct_vip_vol"
    cart_payload = build_cart_payload(
      company: company,
      cart_token: cart_token,
      email: email,
      customer_id: 888,
      items: [ { "id" => 1, "variant_id" => 10, "price" => "100.0", "subscription_price" => "90.0", "quantity" => 1 } ],
      metadata: { "price_type" => "preferred_customer" }
    )
    cart_payload["country_code"] = "US"
    params = { cart: cart_payload }

    metafield = { "key" => "customer_type", "value" => { "customer_type" => TEST_PREFERRED_TYPE } }
    fake_client = stubbed_fluid_client(
      customers_response: [ { "id" => 888, "email" => email } ],
      customer_type_metafield: metafield,
      active_subscriptions: [ { "id" => 1, "status" => "active" } ],
      variant_countries: [ { "country_code" => "US", "cv" => 100, "qv" => 50, "price" => "100.0",
"subscription_price" => "90.0", } ]
    )

    service = Callbacks::VerifyEmailSuccessService.new(params)
    service.define_singleton_method(:fluid_client) { fake_client }

    service.call

    # Volumes track prices exactly: one decision, one write, at subscription level.
    assert_equal 1, fake_client.volume_updates.size
    assert_equal({ "cv" => 90, "qv" => 45 }, fake_client.volume_updates.first[:volumes])
  end

  def test_does_not_update_metadata_when_customer_is_regular
    company = companies(:acme)
    email = "regular@example.com"
    cart_token = "ct_reg_123"
    cart_payload = build_cart_payload(
      company: company,
      cart_token: cart_token,
      email: email,
      items: [ { "id" => 1, "price" => "100.0" } ],
      metadata: { "price_type" => "preferred_customer" }
    )
    params = { cart: cart_payload }

    customer_response = [ { "id" => 777, "email" => email } ]

    metafield = {
      "key" => "customer_type",
      "value" => { "customer_type" => "regular" },
    }

    fake_client = stubbed_fluid_client(
      customers_response: customer_response,
      customer_type_metafield: metafield
    )

    service = Callbacks::VerifyEmailSuccessService.new(params)
    service.define_singleton_method(:fluid_client) { fake_client }

    result = service.call
    assert_equal true, result[:success]
    expected_updates = [
      [ cart_token, { "price_type" => nil } ],
    ]
    assert_equal expected_updates, fake_client.metadata_updates
    assert_equal 1, fake_client.items_prices_updates.size
  end

  def test_does_not_clean_metadata_when_price_type_already_nil
    company = companies(:acme)
    email = "test@example.com"
    cart_token = "ct_123"
    cart_payload = build_cart_payload(
      company: company,
      cart_token: cart_token,
      email: email,
      items: [ { "id" => 1, "price" => "100.0" } ],
      metadata: { "price_type" => nil }
    )
    params = { cart: cart_payload }

    fake_client = stubbed_fluid_client(customers_response: [])

    service = Callbacks::VerifyEmailSuccessService.new(params)
    service.define_singleton_method(:fluid_client) { fake_client }

    result = service.call

    assert_equal true, result[:success]
    # Should not update metadata if already nil
    assert_empty fake_client.metadata_updates
    assert_empty fake_client.items_prices_updates
  end
  def build_cart_payload(company:, cart_token:, email:, customer_id: nil, items: [], metadata: {})
    payload = {
      "id" => 12345,
      "cart_token" => cart_token,
      "company" => {
        "id" => company.fluid_company_id,
        "name" => company.name,
        "subdomain" => "test",
      },
    }
    payload["email"] = email unless email.nil?
    payload["customer_id"] = customer_id if customer_id.present?
    payload["items"] = items if items.any?
    payload["metadata"] = metadata if metadata.any?
    payload
  end


  def stubbed_fluid_client(customers_response: [], customer_type_metafield: nil, get_error: nil,
                          variant_countries: [], active_subscriptions: [])
    StubFluidClient.new(
      customers_response: customers_response,
      customer_type_metafield: customer_type_metafield,
      get_error: get_error,
      variant_countries: variant_countries,
      active_subscriptions: active_subscriptions
    )
  end

  class StubCustomersResource
    def initialize(customers_response:, get_error:)
      @customers_response = customers_response
      @get_error = get_error
    end

    def get(params = {})
      raise @get_error if @get_error
      { "customers" => @customers_response }
    end
  end

  class StubMetafieldsResource
    def initialize(customer_type_metafield:, get_error:)
      @customer_type_metafield = customer_type_metafield
      @get_error = get_error
    end

    def get_by_key(resource_type:, resource_id:, key:)
      raise @get_error if @get_error
      return nil if @customer_type_metafield.nil?

      if key.to_s == "customer_type"
        @customer_type_metafield
      else
        nil
      end
    end
  end

  class StubCartsResource
    attr_reader :metadata_updates, :items_prices_updates, :volume_updates

    def initialize
      @metadata_updates = []
      @items_prices_updates = []
      @volume_updates = []
    end

    def append_metadata(cart_token, metadata)
      @metadata_updates << [ cart_token, metadata ]
      { "success" => true }
    end

    def update_items_prices(cart_token, items_data)
      @items_prices_updates << { token: cart_token, items: items_data }
      { "success" => true }
    end

    def update_item_volumes(cart_token, item_id, volumes)
      @volume_updates << { token: cart_token, item_id: item_id, volumes: volumes }
      { "success" => true }
    end
  end

  # Without this, has_active_subscriptions? hit NoMethodError on the double and the
  # service took its lookup-failed path instead of the "no subscriptions" path it
  # was meant to exercise.
  class StubSubscriptionsResource
    def initialize(get_error:, subscriptions: [])
      @get_error = get_error
      @subscriptions = subscriptions
    end

    def get_by_customer(_customer_id, **_options)
      raise @get_error if @get_error
      { "subscriptions" => @subscriptions }
    end
  end

  class StubVariantsResource
    def initialize(variant_countries)
      @variant_countries = variant_countries
    end

    def get(variant_id)
      { "variant" => { "id" => variant_id, "variant_countries" => @variant_countries } }
    end
  end

  class StubFluidClient
    attr_reader :metadata_updates, :items_prices_updates, :volume_updates

    def initialize(customers_response:, customer_type_metafield:, get_error:, variant_countries: [],
                   active_subscriptions: [])
      @customers_resource = StubCustomersResource.new(
        customers_response: customers_response,
        get_error: get_error
      )
      @metafields_resource = StubMetafieldsResource.new(
        customer_type_metafield: customer_type_metafield,
        get_error: get_error
      )
      @carts_resource = StubCartsResource.new
      @variants_resource = StubVariantsResource.new(variant_countries)
      @subscriptions_resource = StubSubscriptionsResource.new(
        get_error: get_error, subscriptions: active_subscriptions
      )
      @metadata_updates = @carts_resource.metadata_updates
      @items_prices_updates = @carts_resource.items_prices_updates
      @volume_updates = @carts_resource.volume_updates
    end

    def blank?
      false
    end

    def customers
      @customers_resource
    end

    def metafields
      @metafields_resource
    end

    def carts
      @carts_resource
    end

    def variants
      @variants_resource
    end

    def subscriptions
      @subscriptions_resource
    end
  end
end
