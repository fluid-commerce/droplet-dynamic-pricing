module AdminApi
  # Ops endpoint to update the mutable fields of a company/installation record:
  # name, fluid_shop, and active.
  #
  # Motivation: when a Fluid company changes its name (and therefore its
  # shop/subdomain), the stored fluid_shop goes stale and shop-based lookups
  # stop resolving. Setting active: false also deactivates a stale duplicate
  # installation so it stops interfering with shop resolution. This endpoint
  # never deletes — deactivating preserves data and avoids dependent
  # destruction (Company has_many ... dependent: :destroy).
  #
  # Auth: a global ADMIN_API_TOKEN bearer token. Inherits ActionController::API
  # so there is no CSRF token or browser-version gate to trip up curl/ops calls.
  class CompaniesController < ActionController::API
    before_action :authenticate_admin_api_token

    # PATCH /admin_api/company
    #
    # Body: { fluid_company_id: <int>, name?: <str>, fluid_shop?: <str>, active?: <bool> }
    #   - Identify by fluid_company_id (or an explicit `id` primary key).
    #   - fluid_company_id is NOT unique in this schema; if it matches more than
    #     one row we refuse and return the candidate ids so the caller can
    #     re-issue with an unambiguous `id`.
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

    # Resolves the single company to update, or renders an error response and
    # returns nil. Prefers an explicit `id`; otherwise selects by
    # fluid_company_id and guards against the non-unique case.
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

    # Only the fields explicitly present in the request are updated.
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
