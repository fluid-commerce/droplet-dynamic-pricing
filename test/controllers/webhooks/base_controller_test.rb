require "test_helper"

describe Webhooks::BaseController do
  fixtures(:companies)

  def setup
    @company = companies(:acme)
    @webhook_auth_token = Setting.fluid_webhook.auth_token
  end

  describe "authentication" do
    it "requires valid authentication token" do
      post webhook_subscription_started_path, params: {
        company: { fluid_company_id: @company.fluid_company_id },
      }, as: :json

      _(response.status).must_equal 401
      json_response = JSON.parse(response.body)
      _(json_response["error"]).must_equal "Unauthorized"
    end

    it "accepts webhook auth token from AUTH_TOKEN header" do
      Webhooks::SubscriptionStartedService.stub :call, { success: true, message: "Success" } do
        post webhook_subscription_started_path, params: {
          company: { fluid_company_id: @company.fluid_company_id },
        }, headers: { "AUTH_TOKEN" => @webhook_auth_token }, as: :json

        _(response.status).must_equal 200
      end
    end

    it "accepts webhook auth token from X-Auth-Token header" do
      Webhooks::SubscriptionStartedService.stub :call, { success: true, message: "Success" } do
        post webhook_subscription_started_path, params: {
          company: { fluid_company_id: @company.fluid_company_id },
        }, headers: { "X-Auth-Token" => @webhook_auth_token }, as: :json

        _(response.status).must_equal 200
      end
    end

    it "accepts company webhook verification token" do
      Webhooks::SubscriptionStartedService.stub :call, { success: true, message: "Success" } do
        post webhook_subscription_started_path, params: {
          company: { fluid_company_id: @company.fluid_company_id },
        }, headers: { "AUTH_TOKEN" => @company.webhook_verification_token }, as: :json

        _(response.status).must_equal 200
      end
    end

    it "returns not_found when company is not found" do
      post webhook_subscription_started_path, params: {
        company: { fluid_company_id: 999999999 },
      }, headers: { "AUTH_TOKEN" => @webhook_auth_token }, as: :json

      _(response.status).must_equal 404
      json_response = JSON.parse(response.body)
      _(json_response["error"]).must_equal "Company not found"
    end

    it "accepts HTTP_AUTH_TOKEN env variable" do
      Webhooks::SubscriptionStartedService.stub :call, { success: true, message: "Success" } do
        post webhook_subscription_started_path, params: {
          company: { fluid_company_id: @company.fluid_company_id },
        }, env: { "HTTP_AUTH_TOKEN" => @webhook_auth_token }, as: :json

        _(response.status).must_equal 200
      end
    end
  end

  describe "CSRF protection" do
    it "skips CSRF token verification" do
      controller = Webhooks::SubscriptionStartedController.new
      _(controller._process_action_callbacks.map(&:filter).include?(:verify_authenticity_token)).must_equal false
    end
  end
end
