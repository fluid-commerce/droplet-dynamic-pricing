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

  test "call returns failure when cart is blank" do
    service = Callbacks::CartEmailOnCreateService.new({ cart: nil })
    result = service.call

    assert_equal false, result[:success]
    assert_equal "Cart data is missing", result[:message]
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

    assert_equal true, result[:success]
    assert_equal "Both email and customer_id are missing", result[:message]
  end

  test "updates cart metadata when customer_type is preferred_customer" do
    service = Callbacks::CartEmailOnCreateService.new({ cart: @cart_data })
    metadata_called = false

    service.stub(:find_company, @company) do
      service.stub(:get_customer_type_from_metafields,
{ success: true, data: Callbacks::BaseService::PREFERRED_CUSTOMER_TYPE }) do
        service.stub(:update_cart_metadata, ->(cart_token, metadata) {
          metadata_called = true
          assert_equal "ct_52blT6sVvSo4Ck2ygrKyW2", cart_token
          assert_equal({ "price_type" => Callbacks::BaseService::PREFERRED_CUSTOMER_TYPE }, metadata)
        }) do
          result = service.call

          assert_equal true, result[:success]
          assert_includes result[:message], "cart metadata updated"
        end
      end
    end

    assert metadata_called, "update_cart_metadata should have been called"
  end

  test "returns success without metadata when customer_type is not preferred_customer" do
    service = Callbacks::CartEmailOnCreateService.new({ cart: @cart_data })

    service.stub(:find_company, @company) do
      service.stub(:get_customer_type_from_metafields, { success: true, data: "regular_customer" }) do
        result = service.call

        assert_equal true, result[:success]
        assert_includes result[:message], "no special pricing needed"
      end
    end
  end

  test "returns success when customer_type is not found" do
    service = Callbacks::CartEmailOnCreateService.new({ cart: @cart_data })

    service.stub(:find_company, @company) do
      service.stub(:get_customer_type_from_metafields, { success: true, data: nil }) do
        result = service.call

        assert_equal true, result[:success]
        assert_includes result[:message], "Customer type not found"
      end
    end
  end

  test "returns error when company is not found" do
    service = Callbacks::CartEmailOnCreateService.new({ cart: @cart_data })

    service.stub(:find_company, nil) do
      result = service.call

      assert_equal false, result[:success]
      assert_equal "company_not_found", result[:error]
    end
  end

  test "returns error when metafields lookup fails" do
    service = Callbacks::CartEmailOnCreateService.new({ cart: @cart_data })

    service.stub(:find_company, @company) do
      service.stub(:get_customer_type_from_metafields, { success: false, error: "metafields_lookup_failed" }) do
        result = service.call

        assert_equal false, result[:success]
        assert_equal "metafields_lookup_failed", result[:error]
      end
    end
  end

  test "handles cart_token extraction correctly" do
    cart_data_with_different_token = @cart_data.merge("cart_token" => "different_token")
    service = Callbacks::CartEmailOnCreateService.new({ cart: cart_data_with_different_token })
    metadata_called = false

    service.stub(:find_company, @company) do
      service.stub(:get_customer_type_from_metafields,
{ success: true, data: Callbacks::BaseService::PREFERRED_CUSTOMER_TYPE }) do
        service.stub(:update_cart_metadata, ->(cart_token, metadata) {
          metadata_called = true
          assert_equal "different_token", cart_token
        }) do
          service.call
        end
      end
    end

    assert metadata_called, "update_cart_metadata should have been called with correct cart_token"
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
