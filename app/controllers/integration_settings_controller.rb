class IntegrationSettingsController < ApplicationController
  skip_before_action :verify_authenticity_token

  def create
    integration_setting = IntegrationSetting.find_or_initialize_by(company_id: integration_setting_params[:company_id])

    new_credentials = {
      exigo_db_host: integration_setting_params[:exigo_db_host],
      db_exigo_username: integration_setting_params[:db_exigo_username],
      exigo_db_password: integration_setting_params[:exigo_db_password],
      exigo_db_name: integration_setting_params[:exigo_db_name],
      preferred_customer_type_id: integration_setting_params[:preferred_customer_type_id],
    }.compact

    integration_setting.credentials = (integration_setting.credentials || {}).merge(new_credentials)

    integration_setting.save!

    render json: integration_setting, status: :created
  rescue ActiveRecord::RecordInvalid => e
    render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
  end

private

  def integration_setting_params
    params.require(:integration_setting).permit(:company_id, :exigo_db_host, :db_exigo_username, :exigo_db_password,
:exigo_db_name, :preferred_customer_type_id)
  end
end
