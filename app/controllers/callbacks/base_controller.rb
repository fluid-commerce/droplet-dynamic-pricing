class Callbacks::BaseController < ApplicationController
  skip_before_action :verify_authenticity_token

  def create
    result = service_class.call(callback_params)

    if result[:success]
      render json: result
    else
      render json: result, status: :bad_request
    end
  rescue StandardError => e
    Rails.logger.error "Callback error for #{self.class.name}: #{e.message}"
    render json: { success: false, error: e.message }, status: :internal_server_error
  end

private

  def service_class
    raise NotImplementedError, "Subclasses must implement service_class method"
  end

  def permitted_params
    raise NotImplementedError, "Subclasses must implement permitted_params method"
  end

  def callback_params
    permitted_params.to_h.with_indifferent_access
  end
end
