require "test_helper"

class Callbacks::VerifyEmailSuccessServiceTest < ActiveSupport::TestCase
  fixtures(:companies)

  def test_returns_failure_when_email_is_blank
    company = companies(:acme)
    cart_token = "ct_52blT6sVvSo4Ck2ygrKyW2"
    cart_payload = build_cart_payload(company:, cart_token:)

    service = Callbacks::VerifyEmailSuccessService.new(
      email: nil,
      cart_token: cart_token,
      "cart" => cart_payload,
    )

    verification_result = service.call

    assert_equal(false, verification_result[:success])
    assert_equal("Missing email or cart_token", verification_result[:message])
  end

  def test_returns_failure_when_cart_token_is_blank
    company = companies(:acme)
    email_address = "test@example.com"
    cart_payload = build_cart_payload(company:, cart_token: nil)

    service = Callbacks::VerifyEmailSuccessService.new(
      email: email_address,
      cart_token: nil,
      "cart" => cart_payload,
    )

    verification_result = service.call

    assert_equal(false, verification_result[:success])
    assert_equal("Missing email or cart_token", verification_result[:message])
  end

  def test_returns_success_when_customer_is_not_found
    company = companies(:acme)
    email_address = "test@example.com"
    cart_token = "ct_52blT6sVvSo4Ck2ygrKyW2"
    cart_payload = build_cart_payload(company:, cart_token:)
    service = Callbacks::VerifyEmailSuccessService.new(
      email: email_address,
      cart_token: cart_token,
      "cart" => cart_payload,
    )

    with_fluid_client(stubbed_fluid_client(customers_response: [])) do
      verification_result = service.call

      assert_equal(true, verification_result[:success])
      assert_equal("Customer not found for email #{email_address}", verification_result[:message])
    end
  end

  def test_returns_success_when_customer_type_is_blank
    company = companies(:acme)
    email_address = "test@example.com"
    cart_token = "ct_52blT6sVvSo4Ck2ygrKyW2"
    cart_payload = build_cart_payload(company:, cart_token:)
    service = Callbacks::VerifyEmailSuccessService.new(
      email: email_address,
      cart_token: cart_token,
      "cart" => cart_payload,
    )

    customer_response = [
      {
        "id" => 123,
        "email" => email_address,
        "metadata" => {},
      },
    ]

    with_fluid_client(stubbed_fluid_client(customers_response: customer_response)) do
      verification_result = service.call

      assert_equal(true, verification_result[:success])
      assert_equal("Customer type is not set", verification_result[:message])
    end
  end

  def test_updates_cart_metadata_when_customer_is_preferred
    company = companies(:acme)
    email_address = "test@example.com"
    cart_token = "ct_52blT6sVvSo4Ck2ygrKyW2"
    cart_payload = build_cart_payload(company:, cart_token:)
    service = Callbacks::VerifyEmailSuccessService.new(
      email: email_address,
      cart_token: cart_token,
      "cart" => cart_payload,
    )

    customer_response = [
      {
        "id" => 123,
        "email" => email_address,
        "metadata" => {
          "customer_type" => Callbacks::BaseService::PREFERRED_CUSTOMER_TYPE,
        },
      },
    ]
    fake_client = stubbed_fluid_client(customers_response: customer_response)

    with_fluid_client(fake_client) do
      verification_result = service.call

      assert_equal(true, verification_result[:success])
      assert_includes(verification_result[:message], "Email verification successful")
    end

    expected_metadata = { "price_type" => Callbacks::BaseService::PREFERRED_CUSTOMER_TYPE }
    assert_equal([ [ cart_token, expected_metadata ] ], fake_client.metadata_updates)
  end

  def test_does_not_update_cart_metadata_when_customer_is_not_preferred
    company = companies(:acme)
    email_address = "test@example.com"
    cart_token = "ct_52blT6sVvSo4Ck2ygrKyW2"
    cart_payload = build_cart_payload(company:, cart_token:)
    service = Callbacks::VerifyEmailSuccessService.new(
      email: email_address,
      cart_token: cart_token,
      "cart" => cart_payload,
    )

    customer_response = [
      {
        "id" => 123,
        "email" => email_address,
        "metadata" => {
          "customer_type" => "regular_customer",
        },
      },
    ]
    fake_client = stubbed_fluid_client(customers_response: customer_response)

    with_fluid_client(fake_client) do
      verification_result = service.call

      assert_equal(true, verification_result[:success])
      assert_includes(verification_result[:message], "Email verification successful")
    end

    assert_equal([], fake_client.metadata_updates)
  end

  def test_uses_cart_token_from_cart_payload_when_not_passed_explicitly
    company = companies(:acme)
    email_address = "test@example.com"
    cart_token = "ct_52blT6sVvSo4Ck2ygrKyW2"
    cart_payload = build_cart_payload(company:, cart_token:)
    service = Callbacks::VerifyEmailSuccessService.new(
      "email" => email_address,
      "cart" => cart_payload,
    )

    customer_response = [
      {
        "id" => 123,
        "email" => email_address,
        "metadata" => {
          "customer_type" => Callbacks::BaseService::PREFERRED_CUSTOMER_TYPE,
        },
      },
    ]
    fake_client = stubbed_fluid_client(customers_response: customer_response)

    with_fluid_client(fake_client) do
      verification_result = service.call

      assert_equal(true, verification_result[:success])
      assert_includes(verification_result[:message], "Email verification successful")
    end

    assert_equal(cart_token, fake_client.metadata_updates.dig(0, 0))
  end

  def test_supports_string_keys_for_email_and_cart_token
    company = companies(:acme)
    email_address = "test@example.com"
    cart_token = "ct_52blT6sVvSo4Ck2ygrKyW2"
    cart_payload = build_cart_payload(company:, cart_token:)
    service = Callbacks::VerifyEmailSuccessService.new(
      "email" => email_address,
      "cart_token" => cart_token,
      "cart" => cart_payload,
    )

    customer_response = [
      {
        "id" => 123,
        "email" => email_address,
        "metadata" => {
          "customer_type" => Callbacks::BaseService::PREFERRED_CUSTOMER_TYPE,
        },
      },
    ]
    fake_client = stubbed_fluid_client(customers_response: customer_response)

    with_fluid_client(fake_client) do
      verification_result = service.call

      assert_equal(true, verification_result[:success])
      assert_includes(verification_result[:message], "Email verification successful")
    end

    expected_metadata = { "price_type" => Callbacks::BaseService::PREFERRED_CUSTOMER_TYPE }
    assert_equal([ [ cart_token, expected_metadata ] ], fake_client.metadata_updates)
  end

  def test_handles_symbol_keys_in_customer_metadata
    company = companies(:acme)
    email_address = "test@example.com"
    cart_token = "ct_52blT6sVvSo4Ck2ygrKyW2"
    cart_payload = build_cart_payload(company:, cart_token:)
    service = Callbacks::VerifyEmailSuccessService.new(
      email: email_address,
      cart_token: cart_token,
      "cart" => cart_payload,
    )

    customer_response = [
      {
        "id" => 123,
        "email" => email_address,
        metadata: {
          customer_type: Callbacks::BaseService::PREFERRED_CUSTOMER_TYPE,
        },
      },
    ]
    fake_client = stubbed_fluid_client(customers_response: customer_response)

    with_fluid_client(fake_client) do
      verification_result = service.call

      assert_equal(true, verification_result[:success])
      assert_includes(verification_result[:message], "Email verification successful")
    end

    assert_equal(1, fake_client.metadata_updates.length)
  end

private

  def build_cart_payload(company:, cart_token:)
    {
      "id" => 265_327,
      "cart_token" => cart_token,
      "company" => {
        "id" => company.fluid_company_id,
        "name" => company.name,
        "subdomain" => "test",
      },
    }
  end

  def stubbed_fluid_client(customers_response:, get_error: nil, append_error: nil)
    StubFluidClient.new(
      customers_response: customers_response,
      get_error: get_error,
      append_error: append_error,
    )
  end

  def with_fluid_client(fake_client)
    FluidClient.stub(:new, ->(_token) { fake_client }) do
      yield fake_client
    end
  end

  class StubFluidClient
    attr_reader :metadata_updates, :requested_paths

    def initialize(customers_response:, get_error:, append_error:)
      @customers_response = customers_response
      @get_error = get_error
      @append_error = append_error
      @metadata_updates = []
      @requested_paths = []
    end

    def blank?
      false
    end

    def get(path)
      raise @get_error if @get_error

      @requested_paths << path
      { "customers" => @customers_response }
    end

    def carts
      self
    end

    def append_metadata(cart_token, metadata)
      raise @append_error if @append_error

      @metadata_updates << [ cart_token, metadata ]
      {}
    end
  end
end
