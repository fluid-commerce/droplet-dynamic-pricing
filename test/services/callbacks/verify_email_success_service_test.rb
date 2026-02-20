require "test_helper"

class Callbacks::VerifyEmailSuccessServiceTest < ActiveSupport::TestCase
  fixtures(:companies, :integration_settings)

  TEST_PREFERRED_TYPE = "preferred_customer"

  def test_returns_failure_when_email_is_missing_in_cart
    company = companies(:acme)
    cart_payload = build_cart_payload(company: company, cart_token: "ct_123", email: nil)
    params = { cart: cart_payload }

    result = Callbacks::VerifyEmailSuccessService.call(params)

    assert_equal false, result[:success]
    assert_equal "Missing email", result[:message]
  end

  def test_returns_success_with_message_when_customer_not_found
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
    assert_equal "Customer not found for #{email}", result[:message]
    expected_updates = [
      [ cart_token, { "price_type" => nil } ],
    ]
    assert_equal expected_updates, fake_client.metadata_updates
    assert_equal 1, fake_client.items_prices_updates.size
  end

  def test_does_not_clean_metadata_when_customer_not_found_but_has_subscription_in_cart
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
    assert_equal "Customer not found for #{email}", result[:message]
    # Should NOT clean metadata when there's a subscription in cart
    assert_empty fake_client.metadata_updates
    assert_empty fake_client.items_prices_updates
  end

  def test_returns_success_when_email_match_is_not_exact
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
    assert_equal "Customer not found for #{target_email}", result[:message]
  end

  def test_returns_success_with_message_when_customer_id_is_missing
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
    assert_equal "Customer ID missing for #{email}", result[:message]
  end

  def test_returns_success_with_message_when_customer_type_metafield_is_missing
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
    assert_equal "Customer type not set for #{email}", result[:message]
  end

  def test_updates_cart_metadata_when_customer_is_preferred
    company = companies(:acme)
    email = "vip@example.com"
    cart_token = "ct_vip_123"
    cart_payload = build_cart_payload(
      company: company,
      cart_token: cart_token,
      email: email,
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
      customer_type_metafield: metafield
    )

    service = Callbacks::VerifyEmailSuccessService.new(params)
    service.define_singleton_method(:fluid_client) { fake_client }

    result = service.call

    assert_equal true, result[:success]
    expected_updates = [
      [ cart_token, { "price_type" => nil } ],
      [ cart_token, { "price_type" => TEST_PREFERRED_TYPE } ],
    ]
    assert_equal expected_updates, fake_client.metadata_updates
    assert_equal 2, fake_client.items_prices_updates.size
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
  # New customer no-orders pricing tests

  def test_applies_subscription_pricing_when_customer_has_zero_orders
    company = companies(:yoli)
    email = "new@example.com"
    cart_token = "ct_new_123"
    cart_payload = build_cart_payload(
      company: company,
      cart_token: cart_token,
      email: email,
      items: [ { "id" => 1, "price" => "100.0", "subscription_price" => "80.0" } ]
    )
    params = { cart: cart_payload }

    customer_response = [ { "id" => 42, "email" => email, "orders_count" => 0 } ]
    fake_client = stubbed_fluid_client(customers_response: customer_response)

    service = Callbacks::VerifyEmailSuccessService.new(params)
    service.define_singleton_method(:fluid_client) { fake_client }

    result = service.call

    assert_equal true, result[:success]
    assert_equal [ [ cart_token, { "price_type" => TEST_PREFERRED_TYPE } ] ], fake_client.metadata_updates
    assert_equal 1, fake_client.items_prices_updates.size
  end

  def test_applies_subscription_pricing_when_no_customer_record_exists
    company = companies(:yoli)
    email = "brand_new@example.com"
    cart_token = "ct_brand_new_123"
    cart_payload = build_cart_payload(
      company: company,
      cart_token: cart_token,
      email: email,
      items: [ { "id" => 2, "price" => "50.0", "subscription_price" => "40.0" } ]
    )
    params = { cart: cart_payload }

    fake_client = stubbed_fluid_client(customers_response: [])

    service = Callbacks::VerifyEmailSuccessService.new(params)
    service.define_singleton_method(:fluid_client) { fake_client }

    result = service.call

    assert_equal true, result[:success]
    assert_equal [ [ cart_token, { "price_type" => TEST_PREFERRED_TYPE } ] ], fake_client.metadata_updates
    assert_equal 1, fake_client.items_prices_updates.size
  end

  def test_falls_through_to_existing_logic_when_customer_has_orders
    company = companies(:yoli)
    email = "returning@example.com"
    cart_token = "ct_returning_123"
    cart_payload = build_cart_payload(
      company: company,
      cart_token: cart_token,
      email: email,
      items: [ { "id" => 3, "price" => "100.0", "subscription_price" => "80.0" } ]
    )
    params = { cart: cart_payload }

    customer_response = [ { "id" => 99, "email" => email, "orders_count" => 5 } ]
    metafield = { "key" => "customer_type", "value" => { "customer_type" => "regular" } }
    fake_client = stubbed_fluid_client(customers_response: customer_response, customer_type_metafield: metafield)

    service = Callbacks::VerifyEmailSuccessService.new(params)
    service.define_singleton_method(:fluid_client) { fake_client }

    result = service.call

    assert_equal true, result[:success]
    # No new_customer_no_orders event logged
    refute CartPricingEvent.exists?(metadata: { "reason" => "new_customer_no_orders" })
  end

  def test_new_customer_path_runs_first_even_when_customer_is_already_preferred
    company = companies(:yoli)
    email = "preferred_new@example.com"
    cart_token = "ct_pref_new_123"
    cart_payload = build_cart_payload(
      company: company,
      cart_token: cart_token,
      email: email,
      items: [ { "id" => 4, "price" => "100.0", "subscription_price" => "80.0" } ]
    )
    params = { cart: cart_payload }

    customer_response = [ { "id" => 55, "email" => email, "orders_count" => 0 } ]
    metafield = { "key" => "customer_type", "value" => { "customer_type" => TEST_PREFERRED_TYPE } }
    fake_client = stubbed_fluid_client(customers_response: customer_response, customer_type_metafield: metafield)

    service = Callbacks::VerifyEmailSuccessService.new(params)
    service.define_singleton_method(:fluid_client) { fake_client }

    result = service.call

    assert_equal true, result[:success]
    assert_equal [ [ cart_token, { "price_type" => TEST_PREFERRED_TYPE } ] ], fake_client.metadata_updates
  end

  def build_cart_payload(company:, cart_token:, email:, items: [], metadata: {})
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
    payload["items"] = items if items.any?
    payload["metadata"] = metadata if metadata.any?
    payload
  end


  def stubbed_fluid_client(customers_response: [], customer_type_metafield: nil, get_error: nil)
    StubFluidClient.new(
      customers_response: customers_response,
      customer_type_metafield: customer_type_metafield,
      get_error: get_error
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
    attr_reader :metadata_updates, :items_prices_updates

    def initialize
      @metadata_updates = []
      @items_prices_updates = []
    end

    def append_metadata(cart_token, metadata)
      @metadata_updates << [ cart_token, metadata ]
      { "success" => true }
    end

    def update_items_prices(cart_token, items_data)
      @items_prices_updates << { token: cart_token, items: items_data }
      { "success" => true }
    end
  end

  class StubFluidClient
    attr_reader :metadata_updates, :items_prices_updates

    def initialize(customers_response:, customer_type_metafield:, get_error:)
      @customers_resource = StubCustomersResource.new(
        customers_response: customers_response,
        get_error: get_error
      )
      @metafields_resource = StubMetafieldsResource.new(
        customer_type_metafield: customer_type_metafield,
        get_error: get_error
      )
      @carts_resource = StubCartsResource.new
      @metadata_updates = @carts_resource.metadata_updates
      @items_prices_updates = @carts_resource.items_prices_updates
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
  end
end
