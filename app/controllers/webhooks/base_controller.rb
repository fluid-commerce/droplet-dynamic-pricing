class Webhooks::BaseController < ApplicationController
  skip_before_action :verify_authenticity_token
  before_action :authenticate_webhook_token

protected

  def authenticate_webhook_token
    company = find_company
    if company.blank?
      render json: { error: "Company not found" }, status: :not_found
      return
    end

    unless valid_auth_token?(company)
      render json: { error: "Unauthorized" }, status: :unauthorized
    end
  end

  def valid_auth_token?(company)
    auth_header = request.headers["AUTH_TOKEN"] || request.headers["X-Auth-Token"] || request.env["HTTP_AUTH_TOKEN"]
    webhook_auth_token = Setting.fluid_webhook.auth_token

    auth_header.present? && [ webhook_auth_token, company.webhook_verification_token ].include?(auth_header)
  end

  def find_company
    company_id = webhook_params.dig("payload", "company_id") ||
                 webhook_params.dig(:payload, :company_id) ||
                 webhook_params.dig("company_id") ||
                 webhook_params.dig(:company_id)
    Company.find_by(fluid_company_id: company_id) if company_id.present?
  end

  def permitted_params
    raise NotImplementedError, "Subclasses must implement permitted_params method"
  end

  def webhook_params
    permitted_params.to_h.with_indifferent_access
  end
end
