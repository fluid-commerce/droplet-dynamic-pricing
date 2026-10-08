class Admin::IntegrationSettingsController < PublicAdminController
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

  # Runs both Exigo checks against the SAVED credentials and renders the show
  # page with the results. Read-only on both sides: SELECT 1 and a GET.
  def test_connection
    @integration_setting = @company.integration_setting || @company.build_integration_setting
    client = ExigoClient.for_company(@company)
    @connection_results = { "Database" => client.check_database, "API" => client.check_api }
    render :show
  end

private

  def set_current_company
    @company = Company.find_by(droplet_installation_uuid: @dri)

    unless @company
      render plain: "Company not found", status: :not_found
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
        yield_to_enrollment_wholesale
        adjust_volumes_for_subscription
        subscription_volume_source
        exigo_preferred_signal
        preferred_source
        promote_member_type_on_first_subscription
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
