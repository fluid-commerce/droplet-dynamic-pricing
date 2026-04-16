class WebhooksController < ApplicationController
  skip_before_action :verify_authenticity_token
  before_action :validate_droplet_authorization, if: :is_droplet_installation_event?
  before_action :authenticate_webhook_token, unless: :is_droplet_installation_event?

  def create
    effective = webhook_payload
    event_type = "#{effective[:resource]}.#{effective[:event]}"
    version = effective[:version]

    payload = effective.to_unsafe_h.deep_dup

    if EventHandler.route(event_type, payload, version: version)
      # A 202 Accepted indicates that we have accepted the webhook and queued
      # the appropriate background job for processing.
      head :accepted
    else
      head :no_content
    end
  end

private

  # Fluid may send webhooks in two formats:
  #   - Flat: { resource: "droplet", event: "installed", company: {...}, ... }
  #   - Nested: { payload: { resource: "droplet", event: "installed", company: {...}, ... }, ... }
  # This method normalizes access to the effective payload.
  def webhook_payload
    if params[:payload].is_a?(ActionController::Parameters) && params[:payload][:resource].present?
      params[:payload]
    else
      params
    end
  end

  def is_droplet_installation_event?
    effective = webhook_payload
    effective[:resource] == "droplet" && %w[installed uninstalled].include?(effective[:event])
  end

  def authenticate_webhook_token
    company = find_company
    if company.blank?
      render json: { error: "Company not found" }, status: :not_found
    elsif !valid_auth_token?(company)
      render json: { error: "Unauthorized" }, status: :unauthorized
    end
  end

  def valid_auth_token?(company)
    # Check header auth token first, then fall back to params
    auth_header = request.headers["AUTH_TOKEN"] || request.headers["X-Auth-Token"] || request.env["HTTP_AUTH_TOKEN"]
    webhook_auth_token = Setting.fluid_webhook.auth_token

    auth_header.present? && [ webhook_auth_token, company.webhook_verification_token ].include?(auth_header)
  end

  def find_company
    Company.find_by(fluid_company_id: company_params[:fluid_company_id])
  end

  def company_params
    webhook_payload.require(:company).permit(
      :company_droplet_uuid,
      :droplet_installation_uuid,
      :fluid_company_id,
      :webhook_verification_token,
      :authentication_token
    )
  end
end
