require "test_helper"

class Callbacks::CartEmailOnCreateServiceTest < ActiveSupport::TestCase
  fixtures(:companies)

  def setup
    @company = companies(:acme)
    @email = "test@example.com"
    @customer_id = 123
    @cart_data = {
      "id" => 265327,
      "cart_token" => "ct_52blT6sVvSo4Ck2ygrKyW2",
      "email" => @email,
      "customer_id" => @customer_id,
      "company" => {
        "id" => @company.fluid_company_id,
        "name" => @company.name,
        "subdomain" => "test",
      },
    }
  end

  test "call returns success when cart is blank" do
    service = Callbacks::CartEmailOnCreateService.new({ cart: nil })
    result = service.call

    assert_equal({ success: true }, result)
  end

  test "call returns success when email and customer_id are blank" do
    cart_without_email_or_customer = {
      "id" => 265327,
      "cart_token" => "ct_52blT6sVvSo4Ck2ygrKyW2",
      "company" => {
        "id" => @company.fluid_company_id,
      },
    }
    service = Callbacks::CartEmailOnCreateService.new({ cart: cart_without_email_or_customer })
    result = service.call

    assert_equal({ success: true }, result)
  end

  test "returns metadata when customer_type is preferred_customer" do
    metafields_response = {
      "metafields" => [
        {
          "key" => "customer_type",
          "value" => {
            "customer_type" => "preferred_customer",
          },
        },
      ],
    }

    service = Callbacks::CartEmailOnCreateService.new({ cart: @cart_data })

    service.stub(:find_company, @company) do
      service.stub(:get_customer_type_from_metafields, "preferred_customer") do
        result = service.call

        assert_equal({ success: true, metadata: { "price_type" => "preferred_customer" } }, result)
      end
    end
  end

  test "returns success without metadata when customer_type is not preferred_customer" do
    service = Callbacks::CartEmailOnCreateService.new({ cart: @cart_data })

    service.stub(:find_company, @company) do
      service.stub(:get_customer_type_from_metafields, "regular_customer") do
        result = service.call

        assert_equal({ success: true }, result)
      end
    end
  end

  test "returns success without metadata when customer_type is nil" do
    service = Callbacks::CartEmailOnCreateService.new({ cart: @cart_data })

    service.stub(:find_company, @company) do
      service.stub(:get_customer_type_from_metafields, nil) do
        result = service.call

        assert_equal({ success: true }, result)
      end
    end
  end

  test "get_customer_id_by_email returns customer id when customer is found" do
    service = Callbacks::CartEmailOnCreateService.new({ cart: @cart_data })

    customer_data = { "id" => 123, "email" => "test@example.com" }

    service.stub(:find_company, @company) do
      service.stub(:get_customer_by_email, customer_data) do
        customer_id = service.send(:get_customer_id_by_email, @email)

        assert_equal 123, customer_id
      end
    end
  end

  test "get_customer_id_by_email returns nil when customer is not found" do
    service = Callbacks::CartEmailOnCreateService.new({ cart: @cart_data })

    service.stub(:find_company, @company) do
      service.stub(:get_customer_by_email, nil) do
        customer_id = service.send(:get_customer_id_by_email, @email)

        assert_nil customer_id
      end
    end
  end

  test "class method call works" do
    service_instance = Minitest::Mock.new
    service_instance.expect(:call, { success: true })

    Callbacks::CartEmailOnCreateService.stub(:new, ->(params) { service_instance }) do
      result = Callbacks::CartEmailOnCreateService.call({ cart: @cart_data })

      assert_equal({ success: true }, result)
    end

    service_instance.verify
  end
end

