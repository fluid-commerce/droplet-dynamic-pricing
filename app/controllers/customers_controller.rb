class CustomersController < ApplicationController
  before_action :store_dri_in_session
  before_action :find_company_by_dri

  def index
    page = params[:page].presence || 1
    per_page = params[:per_page].presence || 25

    client = FluidClient.new(@company.authentication_token)
    response = client.customers.get(page: page, per_page: per_page)

    @customers = response["customers"] || []
    @meta = response["meta"] || {}
  end

private

  def store_dri_in_session
    dri = params[:dri]

    if dri.present?
      session[:dri] = dri
    elsif session[:dri].blank?
      render json: { error: "DRI parameter is required" }, status: :bad_request
    end
  end

  def find_company_by_dri
    dri = session[:dri]

    unless dri.present?
      render json: { error: "DRI parameter is required" }, status: :bad_request
    end

    @company = Company.find_by(droplet_installation_uuid: dri)

    unless @company
      render json: { error: "Company not found with DRI: #{dri}" }, status: :not_found
    end
  end
end
