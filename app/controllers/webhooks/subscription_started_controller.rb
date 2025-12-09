class Webhooks::SubscriptionStartedController < Webhooks::BaseController
  def create
    company = find_company
    result = Webhooks::SubscriptionStartedService.call(webhook_params, company)

    if result[:success]
      render json: result, status: :ok
    else
      render json: result, status: :bad_request
    end
  rescue StandardError => e
    Rails.logger.error "Webhook error for SubscriptionStarted: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    render json: { success: false, error: e.message }, status: :internal_server_error
  end

private

  def permitted_params
    params.permit(
      :event_name, :schema_version, :schema_hash, :company_id, :resource_name, :resource, :event,
      subscription: {}
    )
  end
end
