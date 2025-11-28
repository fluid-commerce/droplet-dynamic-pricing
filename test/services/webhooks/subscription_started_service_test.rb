require "test_helper"

class Webhooks::SubscriptionStartedServiceTest < ActiveSupport::TestCase
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

  test "updates customer_type to preferred_customer when subscription starts" do
    service = Webhooks::SubscriptionStartedService.new(@webhook_params, @company)

    # Stub update_customer_type
    service.stub :update_customer_type, ->(*args) { nil } do
      result = service.call

      _(result[:success]).must_equal true
      _(result[:message]).must_equal "Subscription started webhook processed successfully"
    end
  end

  test "returns error when customer_id is missing" do
    webhook_params = { "company" => { "fluid_company_id" => @company.fluid_company_id } }

    result = Webhooks::SubscriptionStartedService.call(webhook_params, @company)

    _(result[:success]).must_equal false
    _(result[:error]).must_equal "Customer ID not found in webhook params"
  end

  test "handles errors gracefully" do
    service = Webhooks::SubscriptionStartedService.new(@webhook_params, @company)

    service.stub :update_customer_type, ->(*args) { raise StandardError, "API Error" } do
      result = service.call

      _(result[:success]).must_equal false
      _(result[:error]).must_equal "API Error"
    end
  end
end

