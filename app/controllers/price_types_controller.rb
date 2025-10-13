class PriceTypesController < ApplicationController
  before_action :store_dri_in_session
  before_action :find_company_by_dri

  def index
    @price_types = @company.price_types.order(:name)
  end

  def new
    @price_type = @company.price_types.new
  end

  def create
    @price_type = @company.price_types.new(price_type_params)

    if @price_type.save
      redirect_to price_types_path, notice: "Price type created"
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    @price_type = @company.price_types.find(params[:id])
  end

  def update
    @price_type = @company.price_types.find(params[:id])

    if @price_type.update(price_type_params)
      redirect_to price_types_path, notice: "Price type updated"
    else
      render :edit, status: :unprocessable_entity
    end
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

  def price_type_params
    params.require(:price_type).permit(:name)
  end
end
