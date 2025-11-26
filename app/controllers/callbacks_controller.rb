class CallbacksController < ApplicationController
  skip_before_action :verify_authenticity_token

  def create
    callback_name = params[:callback_name]
    service = SubscriptionCallbackService.new(callback_params)

    result = case callback_name
    when "subscription_added"
      service.handle_subscription_added
    when "subscription_removed"
      service.handle_subscription_removed
    when "item_added"
      service.handle_item_added
    else
      { success: false, error: "Unknown callback: #{callback_name}" }
    end

    if result[:success]
      render json: result
    else
      render json: result, status: :bad_request
    end
  rescue StandardError => e
    Rails.logger.error "Callback error for #{callback_name}: #{e.message}"
    render json: { success: false, error: e.message }, status: :internal_server_error
  end

private

  def callback_params
    params.permit!.to_h.with_indifferent_access
  end
end
