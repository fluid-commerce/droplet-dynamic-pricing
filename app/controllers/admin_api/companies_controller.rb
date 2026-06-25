module AdminApi
  class CompaniesController < ActionController::API
    before_action :authenticate_admin_api_token

    def update
      company = find_target_company
      return if performed?

      attrs = update_attributes
      if attrs.empty?
        render json: {
          error: "At least one of `name`, `fluid_shop`, or `active` must be provided",
        }, status: :unprocessable_entity
        return
      end

      if company.update(attrs)
        render json: { company: serialize(company) }, status: :ok
      else
        render json: {
          error: "Update failed",
          details: company.errors.full_messages,
        }, status: :unprocessable_entity
      end
    end

  private

    def authenticate_admin_api_token
      expected = ENV["ADMIN_API_TOKEN"].to_s
      provided = request.authorization.to_s.sub(/\ABearer /, "")

      authorized =
        expected.present? &&
        provided.present? &&
        ActiveSupport::SecurityUtils.secure_compare(provided, expected)

      return if authorized

      render json: { error: "Unauthorized" }, status: :unauthorized
    end

    def find_target_company
      if params[:id].present?
        company = Company.find_by(id: params[:id])
        if company.nil?
          render json: { error: "Company not found for id: #{params[:id]}" }, status: :not_found
        end
        return company
      end

      if params[:fluid_company_id].present?
        scope = Company.where(fluid_company_id: params[:fluid_company_id])
        case scope.count
        when 0
          render json: {
            error: "Company not found for fluid_company_id: #{params[:fluid_company_id]}",
          }, status: :not_found
          nil
        when 1
          scope.first
        else
          render json: {
            error: "Multiple companies match fluid_company_id: #{params[:fluid_company_id]}. " \
                   "Re-call with an explicit `id`.",
            candidates: scope.order(:id).map { |c| serialize(c) },
          }, status: :conflict
          nil
        end
      else
        render json: { error: "Provide `fluid_company_id` or `id`" }, status: :unprocessable_entity
        nil
      end
    end

    def update_attributes
      attrs = {}
      attrs[:name] = params[:name] if params.key?(:name)
      attrs[:fluid_shop] = params[:fluid_shop] if params.key?(:fluid_shop)
      if params.key?(:active)
        attrs[:active] = ActiveModel::Type::Boolean.new.cast(params[:active])
      end
      attrs
    end

    def serialize(company)
      {
        id: company.id,
        fluid_company_id: company.fluid_company_id,
        name: company.name,
        fluid_shop: company.fluid_shop,
        active: company.active,
        droplet_installation_uuid: company.droplet_installation_uuid,
      }
    end
  end
end
