class Admin::IntegrationSettingsController < AdminController
  before_action :set_current_company

  def show
    @integration_setting = @company.integration_setting || @company.build_integration_setting
  end

  def edit
    @integration_setting = @company.integration_setting || @company.build_integration_setting
  end

  def update
    @integration_setting = @company.integration_setting || @company.build_integration_setting

    if @integration_setting.update(integration_setting_params)
      redirect_to admin_integration_setting_path(dri: @dri), notice: "Integration settings updated successfully"
    else
      render :edit
    end
  end

private

  def set_current_company
    @company = Company.find_by(droplet_installation_uuid: @dri)

    unless @company
      redirect_to admin_dashboard_index_path, alert: "Company not found"
    end
  end

  def integration_setting_params
    params.require(:integration_setting).permit(
      :enabled,
      settings: %i[
        preferred_customer_type_id
        retail_customer_type_id
        api_delay_seconds
        snapshots_to_keep
        daily_warmup_limit
      ],
      credentials: %i[
        exigo_db_host
        exigo_db_username
        exigo_db_password
        exigo_db_name
        api_base_url
        api_username
        api_password
      ]
    )
  end
end
