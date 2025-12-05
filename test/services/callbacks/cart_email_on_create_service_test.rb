require "test_helper"

class Callbacks::CartEmailOnCreateServiceTest < ActiveSupport::TestCase
  fixtures(:companies)

  TEST_PREFERRED_TYPE = "preferred_customer"

  def company
    companies(:acme)
  end

  def cart_data
    {
      "id" => 265327,
      "cart_token" => "ct_52blT6sVvSo4Ck2ygrKyW2",
      "email" => "test@example.com",
      "company" => {
        "id" => company.fluid_company_id,
        "name" => company.name,
        "subdomain" => "test",
      },
    }
  end

  def callback_params
    { cart: cart_data }
  end

  test "call returns failure when cart is blank" do
    service = Callbacks::CartEmailOnCreateService.new({ cart: nil })
    result = service.call

    assert_equal false, result[:success]
    assert_equal "Cart is blank", result[:message]
  end

  test "call returns failure when email is blank" do
    cart_without_email = cart_data.dup
    cart_without_email.delete("email")

    service = Callbacks::CartEmailOnCreateService.new({ cart: cart_without_email })
    result = service.call

    assert_equal false, result[:success]
    assert_equal "Email is blank", result[:message]
  end

  test "returns metadata when customer_type is preferred_customer" do
    email = cart_data["email"]
    customer_response = [ { "id" => 888, "email" => email } ]

    metafield = {
      "key" => "customer_type",
      "value" => { "customer_type" => TEST_PREFERRED_TYPE },
    }

    fake_client = stubbed_fluid_client(
      customers_response: customer_response,
      customer_type_metafield: metafield
    )

    service = Callbacks::CartEmailOnCreateService.new(callback_params)
    service.define_singleton_method(:fluid_client) { fake_client }

    result = service.call

    assert_equal true, result[:success]
    assert_equal({ "price_type" => TEST_PREFERRED_TYPE }, result[:metadata])
  end

  test "returns success without metadata when customer_type is not preferred_customer" do
    email = cart_data["email"]
    customer_response = [ { "id" => 777, "email" => email } ]

    metafield = {
      "key" => "customer_type",
      "value" => { "customer_type" => "regular" },
    }

    fake_client = stubbed_fluid_client(
      customers_response: customer_response,
      customer_type_metafield: metafield
    )

    service = Callbacks::CartEmailOnCreateService.new(callback_params)
    service.define_singleton_method(:fluid_client) { fake_client }

    result = service.call

    assert_equal true, result[:success]
    assert_includes result[:message], "no special pricing needed"
  end

  test "returns success when customer is not found" do
    email = cart_data["email"]
    fake_client = stubbed_fluid_client(customers_response: [])

    service = Callbacks::CartEmailOnCreateService.new(callback_params)
    service.define_singleton_method(:fluid_client) { fake_client }

    result = service.call

    assert_equal true, result[:success]
    assert_includes result[:message], "no special pricing needed"
  end

  test "returns success when customer_id is missing" do
    email = cart_data["email"]
    customer_response = [ { "email" => email, "id" => nil } ]
    fake_client = stubbed_fluid_client(customers_response: customer_response)

    service = Callbacks::CartEmailOnCreateService.new(callback_params)
    service.define_singleton_method(:fluid_client) { fake_client }

    result = service.call

    assert_equal true, result[:success]
    assert_includes result[:message], "no special pricing needed"
  end

  test "returns success when customer_type_metafield is missing" do
    email = cart_data["email"]
    customer_response = [ { "id" => 999, "email" => email } ]
    fake_client = stubbed_fluid_client(
      customers_response: customer_response,
      customer_type_metafield: nil
    )

    service = Callbacks::CartEmailOnCreateService.new(callback_params)
    service.define_singleton_method(:fluid_client) { fake_client }

    result = service.call

    assert_equal true, result[:success]
    assert_includes result[:message], "no special pricing needed"
  end

  test "returns error when customer lookup fails" do
    email = cart_data["email"]
    fake_client = stubbed_fluid_client(
      customers_response: [],
      get_error: StandardError.new("Network error")
    )

    service = Callbacks::CartEmailOnCreateService.new(callback_params)
    service.define_singleton_method(:fluid_client) { fake_client }

    result = service.call

    assert_equal false, result[:success]
    assert_equal "Customer type not found for #{email}", result[:message]
  end

  test "handles StandardError gracefully" do
    service = Callbacks::CartEmailOnCreateService.new(callback_params)

    service.stub(:fetch_and_validate_customer_type, ->(_email) { raise StandardError.new("Network error") }) do
      assert_raises(StandardError) do
        service.call
      end
    end
  end

  test "class method call works" do
    service_instance = Minitest::Mock.new
    service_instance.expect(:call, { success: true })

    Callbacks::CartEmailOnCreateService.stub(:new, ->(_params) { service_instance }) do
      result = Callbacks::CartEmailOnCreateService.call(callback_params)

      assert_equal({ success: true }, result)
    end

    service_instance.verify
  end

private

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

  class StubFluidClient
    def initialize(customers_response:, customer_type_metafield:, get_error:)
      @customers_resource = StubCustomersResource.new(
        customers_response: customers_response,
        get_error: get_error
      )
      @metafields_resource = StubMetafieldsResource.new(
        customer_type_metafield: customer_type_metafield,
        get_error: get_error
      )
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
  end
end
