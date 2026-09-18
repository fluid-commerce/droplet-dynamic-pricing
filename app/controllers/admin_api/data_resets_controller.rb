module AdminApi
  # Per-company data reset.
  #
  #   POST /admin_api/data_reset
  #     Authorization: Bearer $DATA_RESET_TOKEN
  #     { fluid_company_id: | id:, confirm:, dry_run: }
  #
  # Written for the Yoli production cutover. The Fluid company does not change
  # there — same fluid_company_id, same installation, same callback
  # registrations — so this is not a migration. It removes the operational data
  # the droplet accumulated while its Exigo credentials pointed at sandbox, and
  # leaves everything that makes the droplet work untouched.
  #
  # Three guards, because this deletes:
  #
  #   - Its own DATA_RESET_TOKEN, not the ADMIN_API_TOKEN that
  #     AdminApi::CompaniesController uses. A destructive endpoint should not
  #     share a credential with a rename. Unset authorises nobody.
  #   - `confirm` must equal the target's fluid_shop, so a mistyped
  #     fluid_company_id is refused rather than resetting a company the caller
  #     never named.
  #   - `dry_run` is on unless the request carries an explicit false. Not
  #     "unless it carries something falsy" — see the cast below.
  #
  # Target the company by `fluid_company_id`, or by `id` when that is ambiguous.
  class DataResetsController < ActionController::API
    before_action :authenticate_data_reset_token

    # Operational data, scoped by company_id. `events` is the webhook delivery
    # log — the payloads we received — not a subscription, so clearing it
    # unsubscribes nothing.
    PURGED_TABLES = %w[
      events
      cart_pricing_events
      customer_type_transactions
      exigo_autoship_snapshots
    ].freeze

    # Company-scoped, but configuration: the installation itself, the price
    # types an operator defined, and the Exigo credentials in
    # integration_settings.credentials.
    PRESERVED_TABLES = %w[
      companies
      price_types
      integration_settings
    ].freeze

    # No company_id at all, so a per-company reset cannot filter them and must
    # not pretend to.
    #
    # `fluid_callback_registrations` is listed even though nothing in THIS app
    # reads it. It is created by db/migrate/20260903000001 and written by the
    # Next port, which serves the same company out of this same database: it
    # holds the token_digest each inbound callback signature is verified
    # against. A delete here would break callbacks over there, with the symptom
    # being "the prices are wrong" and nothing logged as an error.
    OUT_OF_SCOPE_TABLES = %w[
      callbacks
      webhooks
      settings
      users
      fluid_callback_registrations
    ].freeze

    # Scopes to clear, in the order they are reported.
    #
    # `exigo_autoship_snapshots` is queried through its model rather than
    # through an association because `Company` does not declare one — the table
    # has a company_id and the Prisma schema next door models the relation, but
    # the Rails model never got it. Adding `has_many ... dependent: :destroy`
    # here would change what destroying a Company does, which is not this
    # change's business.
    PURGE_SCOPES = {
      "events" => ->(company) { company.events },
      "cart_pricing_events" => ->(company) { company.cart_pricing_events },
      "customer_type_transactions" => ->(company) { company.customer_type_transactions },
      "exigo_autoship_snapshots" => ->(company) { ExigoAutoshipSnapshot.where(company_id: company.id) },
    }.freeze

    def create
      company = resolve_company
      return if performed?

      if company.fluid_shop != params[:confirm]
        render json: {
          error: "`confirm` does not match the company's fluid_shop — refusing to reset",
        }, status: :unprocessable_entity
        return
      end

      # Only an explicit false disarms this. `.nil? || cast(...)` looked
      # equivalent and was not: ActiveModel::Type::Boolean#cast("") is nil, not
      # false, so an empty string — an untouched form field, a
      # --data-urlencode with an unset variable, a client that serialises
      # blanks — skipped the nil branch, cast to nil, and fell through to a
      # real delete. Anything that is not false now leaves the dry run on.
      dry_run = ActiveModel::Type::Boolean.new.cast(params[:dry_run]) != false
      deleted = {}

      ActiveRecord::Base.transaction do
        PURGE_SCOPES.each do |table, build_scope|
          scope = build_scope.call(company)
          deleted[table] = dry_run ? scope.count : scope.delete_all
        end
      end

      Rails.logger.info(
        "[DataReset] #{dry_run ? 'dry run' : 'APPLIED'} for company #{company.id} " \
        "(#{company.fluid_shop}): #{deleted.to_json}",
      )

      render json: {
        dry_run: dry_run,
        company: {
          id: company.id,
          fluid_company_id: company.fluid_company_id,
          fluid_shop: company.fluid_shop,
          name: company.name,
        },
        deleted: deleted,
        preserved: PRESERVED_TABLES,
        out_of_scope: OUT_OF_SCOPE_TABLES,
      }, status: :ok
    end

  private

    def authenticate_data_reset_token
      expected = ENV["DATA_RESET_TOKEN"].to_s
      provided = request.authorization.to_s.sub(/\ABearer /, "")

      authorized =
        expected.present? &&
        provided.present? &&
        ActiveSupport::SecurityUtils.secure_compare(provided, expected)

      return if authorized

      render json: { error: "Unauthorized" }, status: :unauthorized
    end

    # `fluid_company_id` carries no unique index on `companies` — Rails never
    # added one — so a reinstall can leave two rows for the same Fluid company.
    # An ambiguous answer is refused rather than resolved by picking one:
    # resetting a single row would clear half the data and report success.
    #
    # `id` is the way out of that refusal, matching
    # AdminApi::CompaniesController. It has to exist: this lookup deliberately
    # does NOT filter by `active`, so deactivating the stale row changes nothing
    # and a retry would hit the same 409 — telling an operator to deactivate and
    # retry would be sending them in a circle at the worst possible moment.
    def resolve_company
      if params[:id].present?
        company = Company.find_by(id: params[:id])
        if company.nil?
          render json: { error: "Company not found for id: #{params[:id]}" }, status: :not_found
        end
        return company
      end

      matches = Company.where(fluid_company_id: params[:fluid_company_id]).order(:created_at)

      if matches.empty?
        render json: {
          error: "Company not found for fluid_company_id: #{params[:fluid_company_id]}",
        }, status: :not_found
        return nil
      end

      if matches.size > 1
        render json: {
          error: "#{matches.size} installations share fluid_company_id " \
                 "#{params[:fluid_company_id]}. Re-call with an explicit `id`.",
          company_ids: matches.map(&:id),
        }, status: :conflict
        return nil
      end

      matches.first
    end
  end
end
