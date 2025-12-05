class HomeController < ApplicationController
  def index
    @company_id = Company.find_by(droplet_installation_uuid: params[:dri])&.id
    @integration_settings = IntegrationSetting.find_by(company_id: @company_id)
  end
end
