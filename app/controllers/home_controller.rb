class HomeController < ApplicationController
  def index
    @company_id = Company.find_by(droplet_installation_uuid: params[:dri])&.id
  end
end
