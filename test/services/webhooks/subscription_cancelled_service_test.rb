require "test_helper"

class Webhooks::SubscriptionCancelledServiceTest < ActiveSupport::TestCase
  fixtures(:companies)

  def setup
    @company = companies(:acme)
    @webhook_params = {
      "subscription" => {
        "id" => 12345,
        "customer_id" => 6834670,
      },
      "company" => {
        "fluid_company_id" => @company.fluid_company_id,
      },
    }
  end

  test "updates customer_type to null when no other active subscriptions" do
    service = Webhooks::SubscriptionCancelledService.new(@webhook_params, @company)

    # Stub has_other_active_subscriptions? to return false
    service.stub :has_other_active_subscriptions?, ->(*args) { false } do
      # Stub update_customer_type
      service.stub :update_customer_type, ->(*args) { nil } do
        result = service.call

        _(result[:success]).must_equal true
        _(result[:message]).must_equal "Subscription cancelled webhook processed successfully"
      end
    end
  end

  test "does not update customer_type when customer has other active subscriptions" do
    service = Webhooks::SubscriptionCancelledService.new(@webhook_params, @company)

    # Stub has_other_active_subscriptions? to return true
    service.stub :has_other_active_subscriptions?, ->(*args) { true } do
      result = service.call

      _(result[:success]).must_equal true
      _(result[:message]).must_equal "Customer has other active subscriptions, no action taken"
    end
  end

  test "returns error when customer_id is missing" do
    webhook_params = { "company" => { "fluid_company_id" => @company.fluid_company_id } }

    result = Webhooks::SubscriptionCancelledService.call(webhook_params, @company)

    _(result[:success]).must_equal false
    _(result[:error]).must_equal "Customer ID not found in webhook params"
  end

  test "handles errors gracefully" do
    service = Webhooks::SubscriptionCancelledService.new(@webhook_params, @company)

    service.stub :has_other_active_subscriptions?, ->(*args) { raise StandardError, "API Error" } do
      result = service.call

      _(result[:success]).must_equal false
      _(result[:error]).must_equal "API Error"
    end
  end
end

