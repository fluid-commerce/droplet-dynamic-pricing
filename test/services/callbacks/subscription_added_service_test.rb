require "test_helper"

class Callbacks::SubscriptionAddedServiceTest < ActiveSupport::TestCase
  fixtures(:companies)

  def setup
    @company = companies(:acme)
    @cart_data = {
      "id" => 265327,
      "cart_token" => "ct_52blT6sVvSo4Ck2ygrKyW2",
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
          "product" => {
            "price" => "80.0",
          },
        },
        {
          "id" => 674138,
          "price" => "60.0",
          "subscription_price" => "54.0",
          "product" => {
            "price" => "60.0",
          },
        },
      ],
    }
    @callback_params = { cart: @cart_data }
  end

  test "call returns success when cart is blank" do
    service = Callbacks::SubscriptionAddedService.new({ cart: nil })
    result = service.call

    assert_equal({ success: true }, result)
  end

  test "call processes subscription_added successfully" do
    service = Callbacks::SubscriptionAddedService.new(@callback_params)

    service.stub(:find_company, @company) do
      service.stub(:update_cart_metadata, true) do
        service.stub(:update_cart_items_prices, true) do
          result = service.call

          assert_equal({ success: true }, result)
        end
      end
    end
  end

  test "class method call works" do
    # Mock the instance
    service_instance = Minitest::Mock.new
    service_instance.expect(:call, { success: true })

    Callbacks::SubscriptionAddedService.stub(:new, ->(params) { service_instance }) do
      result = Callbacks::SubscriptionAddedService.call(@callback_params)

      assert_equal({ success: true }, result)
    end

    service_instance.verify
  end

  test "updates cart metadata to preferred_customer" do
    service = Callbacks::SubscriptionAddedService.new(@callback_params)
    metadata_called = false
    expected_metadata = { "price_type" => "preferred_customer" }

    service.stub(:find_company, @company) do
      service.stub(:update_cart_metadata, ->(cart_token, metadata) {
        metadata_called = true
        assert_equal "ct_52blT6sVvSo4Ck2ygrKyW2", cart_token
        assert_equal expected_metadata, metadata
      }) do
        service.stub(:update_cart_items_prices, true) do
          service.call
        end
      end
    end

    assert metadata_called, "update_cart_metadata should have been called"
  end

  test "updates items to subscription pricing" do
    service = Callbacks::SubscriptionAddedService.new(@callback_params)
    prices_called_count = 0

    service.stub(:find_company, @company) do
      service.stub(:update_cart_metadata, true) do
        service.stub(:update_cart_items_prices, ->(cart_token, items_data) {
          prices_called_count += 1
          # Now expects all items in one call with subscription prices
          assert_equal "ct_52blT6sVvSo4Ck2ygrKyW2", cart_token
          assert_equal 2, items_data.length
          assert_equal 674137, items_data[0]["id"]
          assert_equal "72.0", items_data[0]["price"]
          assert_equal 674138, items_data[1]["id"]
          assert_equal "54.0", items_data[1]["price"]
        }) do
          service.call
        end
      end
    end

    assert_equal 1, prices_called_count, "update_cart_items_prices should have been called once with all items"
  end
end
