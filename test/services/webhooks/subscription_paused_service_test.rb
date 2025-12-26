require "test_helper"

class Webhooks::SubscriptionPausedServiceTest < ActiveSupport::TestCase
  fixtures(:companies)

  def setup
    @company = companies(:acme)
    @webhook_params = {
      "subscription" => {
        "id" => 12345,
        "customer" => {
          "id" => 6834670,
        },
      },
      "company_id" => @company.fluid_company_id,
    }
  end

  test "updates customer_type to retail when no other active subscriptions" do
    service = Webhooks::SubscriptionPausedService.new(@webhook_params, @company)

    # Stub should_remain_preferred? to return false
    service.stub :should_remain_preferred?, ->(*_args) { false } do
      # Stub set_customer_retail (external API calls)
      service.stub :set_customer_retail, ->(*_args) { } do
        result = service.call

        _(result[:success]).must_equal true
        _(result[:message]).must_equal "Subscription paused webhook processed successfully"
      end
    end
  end

  test "does not update customer_type when customer has other active subscriptions" do
    service = Webhooks::SubscriptionPausedService.new(@webhook_params, @company)

    # Stub should_remain_preferred? to return true (has other subscriptions or Exigo autoship)
    service.stub :should_remain_preferred?, ->(*_args) { true } do
      result = service.call

      _(result[:success]).must_equal true
      _(result[:message]).must_equal "Customer has other subscriptions or Exigo autoship, no action taken"
    end
  end

  test "returns error when customer_id is missing" do
    webhook_params = { "company_id" => @company.fluid_company_id }

    result = Webhooks::SubscriptionPausedService.call(webhook_params, @company)

    _(result[:success]).must_equal false
    _(result[:error]).must_equal "Customer ID not found in webhook params"
  end

  test "handles errors gracefully" do
    service = Webhooks::SubscriptionPausedService.new(@webhook_params, @company)

    service.stub :should_remain_preferred?, ->(*_args) { raise StandardError, "API Error" } do
      result = service.call

      _(result[:success]).must_equal false
      _(result[:error]).must_equal "API Error"
    end
  end
end
