require "test_helper"

class Callbacks::CartItemAddedServiceTest < ActiveSupport::TestCase
  fixtures(:companies)

  def setup
    @company = companies(:acme)
    @cart_data = {
      "id" => 265327,
      "cart_token" => "ct_52blT6sVvSo4Ck2ygrKyW2",
      "metadata" => {
        "price_type" => Callbacks::BaseService::PREFERRED_CUSTOMER_TYPE,
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

  test "call returns failure when cart is blank" do
    service = Callbacks::CartItemAddedService.new({ cart: nil, cart_item: @cart_item })
    result = service.call

    assert_equal false, result[:success]
    assert_equal "Cart or cart_item data is missing", result[:message]
  end

  test "call returns failure when cart_item is blank" do
    service = Callbacks::CartItemAddedService.new({ cart: @cart_data, cart_item: nil })
    result = service.call

    assert_equal false, result[:success]
    assert_equal "Cart or cart_item data is missing", result[:message]
  end

  test "call returns success when price_type is not preferred_customer" do
    cart_without_preferred = @cart_data.dup
    cart_without_preferred["metadata"] = { "price_type" => "regular_customer" }

    service = Callbacks::CartItemAddedService.new({
      cart: cart_without_preferred,
      cart_item: @cart_item,
    })
    result = service.call

    assert_equal true, result[:success]
    assert_equal "Cart does not have preferred_customer pricing", result[:message]
  end

  test "call returns success when price_type is not set" do
    cart_without_price_type = @cart_data.dup
    cart_without_price_type["metadata"] = {}

    service = Callbacks::CartItemAddedService.new({
      cart: cart_without_price_type,
      cart_item: @cart_item,
    })
    result = service.call

    assert_equal true, result[:success]
    assert_equal "Cart does not have preferred_customer pricing", result[:message]
  end

  test "call processes cart_item_added successfully when price_type is preferred_customer" do
    service = Callbacks::CartItemAddedService.new(@callback_params)

    service.stub(:find_company, @company) do
      service.stub(:update_cart_items_prices, true) do
        service.stub(:update_cart_totals, true) do
          result = service.call

          assert_equal true, result[:success]
          assert_includes result[:message], "Cart item updated to subscription price successfully"
        end
      end
    end
  end

  test "updates cart items prices with subscription_price when available" do
    service = Callbacks::CartItemAddedService.new(@callback_params)
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

    service = Callbacks::CartItemAddedService.new({
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
    service = Callbacks::CartItemAddedService.new(@callback_params)
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

  test "call returns success when cart_token is missing" do
    cart_without_token = @cart_data.dup
    cart_without_token.delete("cart_token")

    service = Callbacks::CartItemAddedService.new({
      cart: cart_without_token,
      cart_item: @cart_item,
    })
    result = service.call

    assert_equal true, result[:success]
    assert_includes result[:message], "Cart token is missing, skipping update"
  end

  test "processes cart item successfully with normalized parameters" do
    service = Callbacks::CartItemAddedService.new(@callback_params)

    service.stub(:find_company, @company) do
      service.stub(:update_cart_items_prices, true) do
        service.stub(:update_cart_totals, true) do
          result = service.call

          assert_equal true, result[:success]
          assert_includes result[:message], "Cart item updated to subscription price successfully"
        end
      end
    end
  end

  test "handles mixed key types with indifferent access" do
    # Test with symbol keys at top level and string keys nested
    mixed_params = {
      "cart" => @cart_data,
      :cart_item => @cart_item,
    }

    service = Callbacks::CartItemAddedService.new(mixed_params)

    service.stub(:find_company, @company) do
      service.stub(:update_cart_items_prices, true) do
        service.stub(:update_cart_totals, true) do
          result = service.call

          assert_equal true, result[:success]
        end
      end
    end
  end

  test "returns error when item price update fails" do
    service = Callbacks::CartItemAddedService.new(@callback_params)

    service.stub(:find_company, @company) do
      service.stub(:update_cart_items_prices, -> { raise StandardError.new("API error") }) do
        result = service.call

        assert_equal false, result[:success]
        assert_equal "item_price_update_failed", result[:error]
      end
    end
  end

  test "returns error when cart totals update fails" do
    service = Callbacks::CartItemAddedService.new(@callback_params)

    service.stub(:find_company, @company) do
      service.stub(:update_cart_items_prices, true) do
        service.stub(:update_cart_totals, -> { raise StandardError.new("API error") }) do
          result = service.call

          assert_equal false, result[:success]
          assert_equal "cart_totals_update_failed", result[:error]
        end
      end
    end
  end

  test "returns success when cart items is missing" do
    cart_without_items = @cart_data.dup
    cart_without_items.delete("items")

    service = Callbacks::CartItemAddedService.new({
      cart: cart_without_items,
      cart_item: @cart_item,
    })

    service.stub(:find_company, @company) do
      service.stub(:update_cart_items_prices, true) do
        result = service.call

        assert_equal true, result[:success]
      end
    end
  end

  test "returns error when cart items is not an array" do
    cart_with_invalid_items = @cart_data.dup
    cart_with_invalid_items["items"] = "not_an_array"

    service = Callbacks::CartItemAddedService.new({
      cart: cart_with_invalid_items,
      cart_item: @cart_item,
    })

    service.stub(:find_company, @company) do
      service.stub(:update_cart_items_prices, true) do
        result = service.call

        assert_equal false, result[:success]
        assert_equal "invalid_cart_items_format", result[:error]
        assert_includes result[:message], "Cart items must be an Array"
      end
    end
  end

  test "returns success when cart items is empty array" do
    cart_with_empty_items = @cart_data.dup
    cart_with_empty_items["items"] = []

    service = Callbacks::CartItemAddedService.new({
      cart: cart_with_empty_items,
      cart_item: @cart_item,
    })

    service.stub(:find_company, @company) do
      service.stub(:update_cart_items_prices, true) do
        result = service.call

        assert_equal true, result[:success]
      end
    end
  end

  test "returns error when cart_item id is missing" do
    cart_item_without_id = @cart_item.dup
    cart_item_without_id.delete("id")

    service = Callbacks::CartItemAddedService.new({
      cart: @cart_data,
      cart_item: cart_item_without_id,
    })

    result = service.call

    assert_equal false, result[:success]
    assert_equal "missing_item_id", result[:error]
    assert_includes result[:message], "Item ID is required"
  end

  test "returns error when cart_item has no price" do
    cart_item_without_price = {
      "id" => 674139,
    }

    service = Callbacks::CartItemAddedService.new({
      cart: @cart_data,
      cart_item: cart_item_without_price,
    })

    result = service.call

    assert_equal false, result[:success]
    assert_equal "missing_item_price", result[:error]
    assert_includes result[:message], "Item price is required"
  end

  test "class method call works" do
    service_instance = Minitest::Mock.new
    service_instance.expect(:call, { success: true })

    Callbacks::CartItemAddedService.stub(:new, ->(params) { service_instance }) do
      result = Callbacks::CartItemAddedService.call(@callback_params)

      assert_equal({ success: true }, result)
    end

    service_instance.verify
  end
end
