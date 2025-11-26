require "test_helper"

class Callbacks::BaseServiceTest < ActiveSupport::TestCase
  fixtures(:companies)

  def setup
    @company = companies(:acme)
    @cart_data = {
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
      ],
    }
    @callback_params = { cart: @cart_data }
  end

  test "class method call creates instance and calls call method" do
    # Create a test service class
    test_service_class = Class.new(Callbacks::BaseService) do
      def call
        { success: true, test: "worked" }
      end
    end

    result = test_service_class.call(@callback_params)

    assert_equal({ success: true, test: "worked" }, result)
  end

  test "call method raises NotImplementedError in base class" do
    service = Callbacks::BaseService.new(@callback_params)

    assert_raises(NotImplementedError) do
      service.call
    end
  end

  test "build_subscription_items_data builds correct data" do
    service = Callbacks::BaseService.new(@callback_params)
    items_data = service.send(:build_subscription_items_data, @cart_data["items"])

    assert_equal 1, items_data.length
    assert_equal 674137, items_data[0]["id"]
    assert_equal "72.0", items_data[0]["price"]
  end

  test "build_regular_items_data builds correct data" do
    service = Callbacks::BaseService.new(@callback_params)
    items_data = service.send(:build_regular_items_data, @cart_data["items"])

    assert_equal 1, items_data.length
    assert_equal 674137, items_data[0]["id"]
    assert_equal "80.0", items_data[0]["price"]
  end

  test "find_company returns nil when company data is missing" do
    service = Callbacks::BaseService.new({ cart: { "company" => nil } })
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
    service = Callbacks::BaseService.new({ cart: cart_with_unknown_company })
    found_company = service.send(:find_company)

    assert_nil found_company
  end
end
