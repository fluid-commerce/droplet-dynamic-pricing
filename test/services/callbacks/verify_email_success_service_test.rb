require "test_helper"

class Callbacks::VerifyEmailSuccessServiceTest < ActiveSupport::TestCase
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
    }
    @email = "test@example.com"
    @cart_token = "ct_52blT6sVvSo4Ck2ygrKyW2"
  end

  test "call returns success when email is blank" do
    service = Callbacks::VerifyEmailSuccessService.new({
      email: nil,
      cart_token: @cart_token,
      cart: @cart_data,
    })
    result = service.call

    assert_equal({ success: true }, result)
  end

  test "call returns success when cart_token is blank" do
    service = Callbacks::VerifyEmailSuccessService.new({
      email: @email,
      cart_token: nil,
      cart: @cart_data,
    })
    result = service.call

    assert_equal({ success: true }, result)
  end

  test "call returns success when customer is not found" do
    service = Callbacks::VerifyEmailSuccessService.new({
      email: @email,
      cart_token: @cart_token,
      cart: @cart_data,
    })

    service.stub(:get_customer_by_email, nil) do
      result = service.call

      assert_equal({ success: true }, result)
    end
  end

  test "call returns success when customer_type is blank" do
    customer = {
      "id" => 123,
      "email" => @email,
      "metadata" => {},
    }

    service = Callbacks::VerifyEmailSuccessService.new({
      email: @email,
      cart_token: @cart_token,
      cart: @cart_data,
    })

    service.stub(:get_customer_by_email, customer) do
      result = service.call

      assert_equal({ success: true, message: "Customer type is not set" }, result)
    end
  end

  test "updates cart metadata when customer_type is preferred_customer" do
    customer = {
      "id" => 123,
      "email" => @email,
      "metadata" => {
        "customer_type" => "preferred_customer",
      },
    }

    service = Callbacks::VerifyEmailSuccessService.new({
      email: @email,
      cart_token: @cart_token,
      cart: @cart_data,
    })

    metadata_called = false
    expected_metadata = { "price_type" => "preferred_customer" }

    service.stub(:find_company, @company) do
      service.stub(:get_customer_by_email, customer) do
        service.stub(:update_cart_metadata, ->(cart_token, metadata) {
          metadata_called = true
          assert_equal @cart_token, cart_token
          assert_equal expected_metadata, metadata
        }) do
          result = service.call

          assert_equal({ success: true }, result)
        end
      end
    end

    assert metadata_called, "update_cart_metadata should have been called"
  end

  test "does not update cart metadata when customer_type is not preferred_customer" do
    customer = {
      "id" => 123,
      "email" => @email,
      "metadata" => {
        "customer_type" => "regular_customer",
      },
    }

    service = Callbacks::VerifyEmailSuccessService.new({
      email: @email,
      cart_token: @cart_token,
      cart: @cart_data,
    })

    metadata_called = false

    service.stub(:get_customer_by_email, customer) do
      service.stub(:update_cart_metadata, ->(cart_token, metadata) {
        metadata_called = true
      }) do
        result = service.call

        assert_equal({ success: true }, result)
      end
    end

    assert_not metadata_called, "update_cart_metadata should not have been called"
  end

  test "handles cart_token from cart data" do
    customer = {
      "id" => 123,
      "email" => @email,
      "metadata" => {
        "customer_type" => "preferred_customer",
      },
    }

    # Pass cart_token as string key to match how it's accessed in the service
    service = Callbacks::VerifyEmailSuccessService.new({
      "email" => @email,
      "cart" => @cart_data,
    })

    metadata_called = false

    service.stub(:find_company, @company) do
      service.stub(:get_customer_by_email, customer) do
        service.stub(:update_cart_metadata, ->(cart_token, metadata) {
          metadata_called = true
          assert_equal @cart_token, cart_token
        }) do
          result = service.call

          assert_equal({ success: true }, result)
        end
      end
    end

    assert metadata_called, "update_cart_metadata should have been called"
  end

  test "handles email and cart_token as string keys" do
    customer = {
      "id" => 123,
      "email" => @email,
      "metadata" => {
        "customer_type" => "preferred_customer",
      },
    }

    service = Callbacks::VerifyEmailSuccessService.new({
      "email" => @email,
      "cart_token" => @cart_token,
      "cart" => @cart_data,
    })

    metadata_called = false

    service.stub(:find_company, @company) do
      service.stub(:get_customer_by_email, customer) do
        service.stub(:update_cart_metadata, ->(cart_token, metadata) {
          metadata_called = true
          assert_equal @cart_token, cart_token
        }) do
          result = service.call

          assert_equal({ success: true }, result)
        end
      end
    end

    assert metadata_called, "update_cart_metadata should have been called"
  end

  test "class method call works" do
    service_instance = Minitest::Mock.new
    service_instance.expect(:call, { success: true })

    Callbacks::VerifyEmailSuccessService.stub(:new, ->(params) { service_instance }) do
      result = Callbacks::VerifyEmailSuccessService.call({
        email: @email,
        cart_token: @cart_token,
        cart: @cart_data,
      })

      assert_equal({ success: true }, result)
    end

    service_instance.verify
  end
end
