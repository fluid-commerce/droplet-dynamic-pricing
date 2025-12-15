class Webhooks::SubscriptionReactivatedController < Webhooks::BaseController
  def create
    company = find_company
    result = Webhooks::SubscriptionReactivatedService.call(webhook_params, company)

    render json: result, status: (result[:success] ? :ok : :bad_request)
  rescue StandardError => e
    Rails.logger.error "Webhook error for SubscriptionReactivated: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    render json: { success: false, error: e.message }, status: :internal_server_error
  end

private

  def permitted_params
    params.permit(
      :event_name,
      :schema_version,
      :schema_hash,
      :company_id,
      :resource_name,
      :resource,
      :event,
      payload: {},
      subscription: {},
      subscription_reactivated: {}
    )
  end
end
