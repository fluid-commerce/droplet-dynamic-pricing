require "test_helper"

class FakeCartsResource
  attr_reader :metadata_calls, :items_prices_calls

  def initialize
    @metadata_calls = []
    @items_prices_calls = []
  end

  def append_metadata(token, metadata)
    @metadata_calls << { token: token, metadata: metadata }
    { "success" => true }
  end

  def update_items_prices(token, items)
    @items_prices_calls << { token: token, items: items }
    { "success" => true }
  end
end

class FakeCustomersResource
  def initialize(customers_response = [])
    @customers_response = customers_response
  end

  def get(params)
    { "customers" => @customers_response }
  end
end

class Callbacks::SubscriptionRemovedServiceTest < ActiveSupport::TestCase
  fixtures(:companies)

  def company
    companies(:acme)
  end

  def cart_data
    {
      "id" => 265327,
      "cart_token" => "ct_52blT6sVvSo4Ck2ygrKyW2",
      "email" => "customer@example.com",
      "company" => {
        "id" => company.fluid_company_id,
        "name" => company.name,
        "subdomain" => "test",
      },
      "items" => [
        { "id" => 674137, "price" => "80.0", "subscription_price" => "72.0" },
        { "id" => 674138, "price" => "60.0", "subscription_price" => "54.0" },
      ],
    }
  end

  def callback_params
    { cart: cart_data }
  end

  test "call returns error when cart is blank" do
    service = Callbacks::SubscriptionRemovedService.new({ cart: nil })
    result = service.call
    assert_equal({ success: false, message: "Cart is blank" }, result)
  end

  test "updates to REGULAR pricing when customer has NO other subscriptions" do
    fake_carts = FakeCartsResource.new
    fake_customers = FakeCustomersResource.new([ { "id" => 123 } ])

    mock_client = Object.new
    mock_client.define_singleton_method(:carts) { fake_carts }
    mock_client.define_singleton_method(:customers) { fake_customers }

    service = Callbacks::SubscriptionRemovedService.new(callback_params)

    service.define_singleton_method(:fluid_client) { mock_client }

    service.stub(:has_active_subscriptions?, false) do
      service.stub(:has_another_subscription_in_cart?, false) do
        result = service.call
        assert result[:success]
      end
    end

    assert_equal 1, fake_carts.metadata_calls.size, "append_metadata should be called once"

    call = fake_carts.metadata_calls.first
    assert_not_nil call
    assert_equal cart_data["cart_token"], call[:token]
    assert_nil call[:metadata].with_indifferent_access[:price_type], "Price type should be nil"

    assert_equal 1, fake_carts.items_prices_calls.size
    items = fake_carts.items_prices_calls.first[:items].map(&:with_indifferent_access)

    item1 = items.find { |i| i[:id].to_s == "674137" }
    item2 = items.find { |i| i[:id].to_s == "674138" }

    assert_equal 80.0, item1[:price].to_f
    assert_equal 60.0, item2[:price].to_f
  end

  test "updates to SUBSCRIPTION pricing when customer HAS active subscriptions" do
    fake_carts = FakeCartsResource.new
    fake_customers = FakeCustomersResource.new([ { "id" => 123 } ])

    mock_client = Object.new
    mock_client.define_singleton_method(:carts) { fake_carts }
    mock_client.define_singleton_method(:customers) { fake_customers }

    service = Callbacks::SubscriptionRemovedService.new(callback_params)

    service.define_singleton_method(:fluid_client) { mock_client }

    service.stub(:has_active_subscriptions?, true) do
      service.stub(:has_another_subscription_in_cart?, false) do
        result = service.call
        assert result[:success]
      end
    end

    assert_equal 1, fake_carts.metadata_calls.size, "append_metadata should be called once"
    call = fake_carts.metadata_calls.first

    if call
      assert_equal "preferred_customer", call[:metadata].with_indifferent_access[:price_type]
    else
      flunk "append_metadata was not called"
    end

    items = fake_carts.items_prices_calls.first[:items].map(&:with_indifferent_access)
    item1 = items.find { |i| i[:id].to_s == "674137" }

    assert_equal 72.0, item1[:price].to_f
  end

  test "removes subscription pricing when email is blank and no subscription items in cart" do
    fake_carts = FakeCartsResource.new

    mock_client = Object.new
    mock_client.define_singleton_method(:carts) { fake_carts }

    cart_without_email = cart_data.merge("email" => nil)
    # Ensure no items have subscription: true
    cart_without_email["items"].each { |item| item.delete("subscription") }

    params = { cart: cart_without_email }

    service = Callbacks::SubscriptionRemovedService.new(params)

    service.define_singleton_method(:fluid_client) { mock_client }

    result = service.call
    assert result[:success]

    assert_equal 1, fake_carts.metadata_calls.size, "append_metadata should have been called even when email is blank"
    call = fake_carts.metadata_calls.first

    assert_not_nil call
    assert_nil call[:metadata].with_indifferent_access[:price_type]

    # Should update to regular prices
    assert_equal 1, fake_carts.items_prices_calls.size
    items = fake_carts.items_prices_calls.first[:items].map(&:with_indifferent_access)
    item1 = items.find { |i| i[:id].to_s == "674137" }
    assert_equal 80.0, item1[:price].to_f, "Should use regular price when no subscription items"
  end

  test "keeps subscription pricing when email is blank but cart has subscription items" do
    fake_carts = FakeCartsResource.new

    mock_client = Object.new
    mock_client.define_singleton_method(:carts) { fake_carts }

    cart_without_email = cart_data.merge("email" => nil)
    # Add subscription: true to items
    cart_without_email["items"].each { |item| item["subscription"] = true }

    params = { cart: cart_without_email }

    service = Callbacks::SubscriptionRemovedService.new(params)

    service.define_singleton_method(:fluid_client) { mock_client }

    result = service.call
    assert result[:success]

    assert_equal 1, fake_carts.metadata_calls.size
    call = fake_carts.metadata_calls.first

    assert_not_nil call
    assert_equal "preferred_customer", call[:metadata].with_indifferent_access[:price_type]

    # Should update to subscription prices
    assert_equal 1, fake_carts.items_prices_calls.size
    items = fake_carts.items_prices_calls.first[:items].map(&:with_indifferent_access)
    item1 = items.find { |i| i[:id].to_s == "674137" }
    assert_equal 72.0, item1[:price].to_f, "Should use subscription price when cart has subscription items"
  end

  test "class method call works" do
    service_instance = Minitest::Mock.new
    service_instance.expect :call, { success: true }

    Callbacks::SubscriptionRemovedService.stub(:new, ->(_params) { service_instance }) do
      result = Callbacks::SubscriptionRemovedService.call(callback_params)
      assert_equal({ success: true }, result)
    end

    service_instance.verify
  end
end
