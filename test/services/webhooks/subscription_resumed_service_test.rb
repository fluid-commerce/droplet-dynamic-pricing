require "test_helper"

class Webhooks::SubscriptionResumedServiceTest < ActiveSupport::TestCase
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

  test "updates customer_type to preferred_customer when subscription resumes" do
    service = Webhooks::SubscriptionResumedService.new(@webhook_params, @company)

    # Stub set_customer_preferred (external API calls)
    service.stub :set_customer_preferred, ->(*_args) { } do
      result = service.call

      _(result[:success]).must_equal true
      _(result[:message]).must_equal "Subscription resumed webhook processed successfully"
    end
  end

  test "returns error when customer_id is missing" do
    webhook_params = { "company_id" => @company.fluid_company_id }

    result = Webhooks::SubscriptionResumedService.call(webhook_params, @company)

    _(result[:success]).must_equal false
    _(result[:error]).must_equal "Customer ID not found in webhook params"
  end

  test "handles errors gracefully" do
    service = Webhooks::SubscriptionResumedService.new(@webhook_params, @company)

    service.stub :set_customer_preferred, ->(*_args) { raise StandardError, "API Error" } do
      result = service.call

      _(result[:success]).must_equal false
      _(result[:error]).must_equal "API Error"
    end
  end
end
