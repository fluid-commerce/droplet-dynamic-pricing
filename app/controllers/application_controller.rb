class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  before_action :set_dri

  def validate_droplet_authorization
    droplet_uuid = params.dig(:company, :droplet_uuid)

    # For installation events, validate format only (starts with drp_)
    # We can't validate against a specific UUID since new installations
    # may have different UUIDs in a multi-tenant environment
    unless droplet_uuid.present? && droplet_uuid.start_with?("drp_")
      render json: { error: "Invalid droplet UUID" }, status: :unauthorized
    end
  end

protected

  def after_sign_in_path_for(resource)
    admin_dashboard_index_path
  end

  def current_ability
    @current_ability ||= Ability.new(user: current_user)
  end

private

  def set_dri
    @dri = params[:dri]
  end
end
