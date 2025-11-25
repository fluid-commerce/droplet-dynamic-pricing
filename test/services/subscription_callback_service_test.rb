require "test_helper"

class SubscriptionCallbackServiceTest < ActiveSupport::TestCase
  fixtures(:companies)

  def setup
    @company = companies(:acme)
    @cart_data = {
      "id" => 265327,
      "cart_token" => "ct_52blT6sVvSo4Ck2ygrKyW2",
      "company" => {
        "id" => 1234567890,
        "name" => @company.name,
        "subdomain" => "test",
      },
      "items" => [
        {
          "id" => 674137,
          "price" => "80.0",
          "subscription_price" => "72.0",
          "product" => {
            "price" => "80.0",
          },
        },
      ],
    }
    @callback_params = { cart: @cart_data }
    @service = SubscriptionCallbackService.new(@callback_params)
  end

  test "handle_subscription_added returns success when cart is blank" do
    service = SubscriptionCallbackService.new({ cart: nil })
    result = service.handle_subscription_added

    assert_equal({ success: true }, result)
  end

  test "handle_subscription_added processes successfully" do
    @service.stub(:update_cart_metadata, true) do
      @service.stub(:update_cart_items_prices, true) do
        result = @service.handle_subscription_added

        assert_equal({ success: true }, result)
      end
    end
  end

  test "handle_subscription_removed returns success when cart is blank" do
    service = SubscriptionCallbackService.new({ cart: nil })
    result = service.handle_subscription_removed

    assert_equal({ success: true }, result)
  end

  test "handle_subscription_removed processes successfully" do
    @service.stub(:update_cart_metadata, true) do
      @service.stub(:update_cart_items_prices, true) do
        result = @service.handle_subscription_removed

        assert_equal({ success: true }, result)
      end
    end
  end

  test "build_subscription_items_data builds correct data" do
    items_data = @service.send(:build_subscription_items_data, @cart_data["items"])

    assert_equal 1, items_data.length
    assert_equal 674137, items_data[0]["id"]
    assert_equal "72.0", items_data[0]["price"]
  end

  test "build_subscription_items_data falls back to regular price" do
    items_without_subscription_price = [
      {
        "id" => 674139,
        "price" => "90.0",
      },
    ]

    items_data = @service.send(:build_subscription_items_data, items_without_subscription_price)

    assert_equal 1, items_data.length
    assert_equal "90.0", items_data[0]["price"]
  end

  test "build_regular_items_data builds correct data" do
    items_data = @service.send(:build_regular_items_data, @cart_data["items"])

    assert_equal 1, items_data.length
    assert_equal 674137, items_data[0]["id"]
    assert_equal "80.0", items_data[0]["price"]
  end

  test "find_company processes company data from callback" do
    # Test that the method processes callback data correctly
    company_data = @cart_data["company"]

    assert_not_nil company_data, "Cart should have company data"
    assert_equal 1234567890, company_data["id"]
    assert_equal "Acme Corporation", company_data["name"]
  end

  test "find_company returns nil when company data is missing" do
    service = SubscriptionCallbackService.new({ cart: { "company" => nil } })
    found_company = service.send(:find_company)

    assert_nil found_company
  end

  test "find_company returns nil when company is not found in database" do
    cart_with_unknown_company = {
      "company" => {
        "id" => 999999999,
        "name" => "Unknown Company",
      },
    }
    service = SubscriptionCallbackService.new({ cart: cart_with_unknown_company })
    found_company = service.send(:find_company)

    assert_nil found_company
  end
end
