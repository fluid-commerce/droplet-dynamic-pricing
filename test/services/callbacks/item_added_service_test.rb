require "test_helper"

class Callbacks::ItemAddedServiceTest < ActiveSupport::TestCase
  fixtures(:companies)

  def setup
    @company = companies(:acme)
    @cart_data = {
      "id" => 265327,
      "cart_token" => "ct_52blT6sVvSo4Ck2ygrKyW2",
      "metadata" => {
        "price_type" => "preferred_customer",
      },
      "company" => {
        "id" => @company.fluid_company_id,
        "name" => @company.name,
        "subdomain" => "test",
      },
      "items" => [
        {
          "id" => 674137,
          "price" => "80.0",
          "subscription_price" => "72.0",
        },
        {
          "id" => 674138,
          "price" => "60.0",
          "subscription_price" => "54.0",
        },
      ],
    }
    @cart_item = {
      "id" => 674139,
      "price" => "100.0",
      "subscription_price" => "90.0",
    }
    @callback_params = {
      cart: @cart_data,
      cart_item: @cart_item,
    }
  end

  test "call returns success when cart is blank" do
    service = Callbacks::ItemAddedService.new({ cart: nil, cart_item: @cart_item })
    result = service.call

    assert_equal({ success: true }, result)
  end

  test "call returns success when cart_item is blank" do
    service = Callbacks::ItemAddedService.new({ cart: @cart_data, cart_item: nil })
    result = service.call

    assert_equal({ success: true }, result)
  end

  test "call returns success when price_type is not preferred_customer" do
    cart_without_preferred = @cart_data.dup
    cart_without_preferred["metadata"] = { "price_type" => "regular_customer" }

    service = Callbacks::ItemAddedService.new({
      cart: cart_without_preferred,
      cart_item: @cart_item,
    })
    result = service.call

    assert_equal({ success: true }, result)
  end

  test "call returns success when price_type is not set" do
    cart_without_price_type = @cart_data.dup
    cart_without_price_type["metadata"] = {}

    service = Callbacks::ItemAddedService.new({
      cart: cart_without_price_type,
      cart_item: @cart_item,
    })
    result = service.call

    assert_equal({ success: true }, result)
  end

  test "call processes item_added successfully when price_type is preferred_customer" do
    service = Callbacks::ItemAddedService.new(@callback_params)

    service.stub(:find_company, @company) do
      service.stub(:update_cart_items_prices, true) do
        service.stub(:update_cart_totals, true) do
          result = service.call

          assert_equal({ success: true }, result)
        end
      end
    end
  end

  test "updates cart items prices with subscription_price when available" do
    service = Callbacks::ItemAddedService.new(@callback_params)
    prices_called = false
    expected_item_data = [
      {
        "id" => @cart_item["id"],
        "price" => @cart_item["subscription_price"],
      },
    ]

    service.stub(:find_company, @company) do
      service.stub(:update_cart_items_prices, ->(cart_token, items_data) {
        prices_called = true
        assert_equal @cart_data["cart_token"], cart_token
        assert_equal expected_item_data, items_data
      }) do
        service.stub(:update_cart_totals, true) do
          service.call
        end
      end
    end

    assert prices_called, "update_cart_items_prices should have been called"
  end

  test "updates cart items prices with regular price when subscription_price is not available" do
    cart_item_without_subscription = {
      "id" => 674140,
      "price" => "50.0",
    }

    service = Callbacks::ItemAddedService.new({
      cart: @cart_data,
      cart_item: cart_item_without_subscription,
    })
    prices_called = false
    expected_item_data = [
      {
        "id" => cart_item_without_subscription["id"],
        "price" => cart_item_without_subscription["price"],
      },
    ]

    service.stub(:find_company, @company) do
      service.stub(:update_cart_items_prices, ->(cart_token, items_data) {
        prices_called = true
        assert_equal @cart_data["cart_token"], cart_token
        assert_equal expected_item_data, items_data
      }) do
        service.stub(:update_cart_totals, true) do
          service.call
        end
      end
    end

    assert prices_called, "update_cart_items_prices should have been called"
  end

  test "updates cart totals with all items using subscription prices" do
    service = Callbacks::ItemAddedService.new(@callback_params)
    totals_called = false

    service.stub(:find_company, @company) do
      service.stub(:update_cart_items_prices, true) do
        service.stub(:update_cart_totals, ->(cart_token, cart_items, use_subscription_prices:) {
          totals_called = true
          assert_equal @cart_data["cart_token"], cart_token
          assert_equal @cart_data["items"], cart_items
          assert_equal true, use_subscription_prices
        }) do
          service.call
        end
      end
    end

    assert totals_called, "update_cart_totals should have been called"
  end

  test "class method call works" do
    service_instance = Minitest::Mock.new
    service_instance.expect(:call, { success: true })

    Callbacks::ItemAddedService.stub(:new, ->(params) { service_instance }) do
      result = Callbacks::ItemAddedService.call(@callback_params)

      assert_equal({ success: true }, result)
    end

    service_instance.verify
  end
end
