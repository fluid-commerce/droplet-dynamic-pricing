require "test_helper"

describe Webhooks::SubscriptionReactivatedController do
  fixtures(:companies)

  def setup
    @company = companies(:acme)
    @webhook_auth_token = Setting.fluid_webhook.auth_token
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

  describe "POST #create" do
    it "returns success when webhook is processed successfully" do
      Webhooks::SubscriptionReactivatedService.stub :call,
        { success: true, message: "Subscription reactivated webhook processed successfully" } do
          post webhook_subscription_reactivated_path, params: @webhook_params,
headers: { "AUTH_TOKEN" => @webhook_auth_token }, as: :json

          _(response.status).must_equal 200
          json_response = JSON.parse(response.body)
          _(json_response["success"]).must_equal true
          _(json_response["message"]).must_equal "Subscription reactivated webhook processed successfully"
        end
    end

    it "returns bad_request when service returns failure" do
      Webhooks::SubscriptionReactivatedService.stub :call,
        { success: false, error: "Customer ID not found in webhook params" } do
          post webhook_subscription_reactivated_path, params: @webhook_params,
headers: { "AUTH_TOKEN" => @webhook_auth_token }, as: :json

          _(response.status).must_equal 400
          json_response = JSON.parse(response.body)
          _(json_response["success"]).must_equal false
          _(json_response["error"]).must_equal "Customer ID not found in webhook params"
        end
    end

    it "returns internal_server_error when service raises an exception" do
      Webhooks::SubscriptionReactivatedService.stub :call, ->(*args) { raise StandardError, "Unexpected error" } do
        post webhook_subscription_reactivated_path, params: @webhook_params,
headers: { "AUTH_TOKEN" => @webhook_auth_token }, as: :json

        _(response.status).must_equal 500
        json_response = JSON.parse(response.body)
        _(json_response["success"]).must_equal false
        _(json_response["error"]).must_equal "Unexpected error"
      end
    end

    it "requires valid authentication token" do
      post webhook_subscription_reactivated_path, params: @webhook_params, as: :json

      _(response.status).must_equal 401
      json_response = JSON.parse(response.body)
      _(json_response["error"]).must_equal "Unauthorized"
    end

    it "accepts company webhook verification token" do
      Webhooks::SubscriptionReactivatedService.stub :call, { success: true, message: "Success" } do
        post webhook_subscription_reactivated_path, params: @webhook_params,
headers: { "AUTH_TOKEN" => @company.webhook_verification_token }, as: :json

        _(response.status).must_equal 200
      end
    end

    it "accepts X-Auth-Token header" do
      Webhooks::SubscriptionReactivatedService.stub :call, { success: true, message: "Success" } do
        post webhook_subscription_reactivated_path, params: @webhook_params,
headers: { "X-Auth-Token" => @webhook_auth_token }, as: :json

        _(response.status).must_equal 200
      end
    end

    it "returns not_found when company is not found" do
      invalid_params = {
        "subscription" => {
          "id" => 12345,
          "customer" => {
            "id" => 6834670,
          },
        },
        "company_id" => 999999999,
      }

      post webhook_subscription_reactivated_path, params: invalid_params,
        headers: { "AUTH_TOKEN" => @webhook_auth_token }, as: :json

      _(response.status).must_equal 404
      json_response = JSON.parse(response.body)
      _(json_response["error"]).must_equal "Company not found"
    end

    it "calls service with correct parameters" do
      service_called = false
      captured_params = nil
      captured_company = nil

      Webhooks::SubscriptionReactivatedService.stub :call, ->(params, company) {
        service_called = true
        captured_params = params
        captured_company = company
        { success: true, message: "Success" }
      } do
        post webhook_subscription_reactivated_path, params: @webhook_params,
headers: { "AUTH_TOKEN" => @webhook_auth_token }, as: :json

        _(service_called).must_equal true
        _(captured_params["subscription"]["id"]).must_equal 12345
        _(captured_params["subscription"]["customer"]["id"]).must_equal 6834670
        _(captured_company).must_equal @company
      end
    end
  end
end
