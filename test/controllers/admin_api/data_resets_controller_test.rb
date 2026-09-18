require "test_helper"

# Tests for the per-company data reset endpoint.
#
# The behaviours pinned here are the ones that make a destructive endpoint safe
# to expose: it fails closed without its own token, it refuses to act on a
# company the caller could not name correctly, and it does nothing at all
# unless the caller explicitly turns the dry run off.
#
# The other load-bearing test is `covers every table in the schema`. Every
# table must be classified as purged, preserved, or out of scope, so adding a
# migration fails this suite until someone decides which it is. Without it, a
# new table silently survives every future reset.
describe AdminApi::DataResetsController do
  fixtures(:companies, :events, :customer_type_transactions)

  RESET_TOKEN = "test-data-reset-token".freeze

  before do
    ENV["DATA_RESET_TOKEN"] = RESET_TOKEN
    ENV.delete("ADMIN_API_TOKEN")
  end

  def auth_headers(token = RESET_TOKEN)
    { "Authorization" => "Bearer #{token}" }
  end

  def reset_params(company, **overrides)
    { fluid_company_id: company.fluid_company_id, confirm: company.fluid_shop }.merge(overrides)
  end

  describe "auth" do
    it "returns 401 when the bearer token is missing" do
      post admin_api_data_reset_url, params: reset_params(companies(:acme)), as: :json

      _(response.status).must_equal 401
    end

    it "returns 401 when the bearer token is wrong" do
      post admin_api_data_reset_url,
           params: reset_params(companies(:acme)),
           headers: auth_headers("wrong-token"),
           as: :json

      _(response.status).must_equal 401
    end

    it "fails closed when DATA_RESET_TOKEN is not configured" do
      ENV.delete("DATA_RESET_TOKEN")

      post admin_api_data_reset_url,
           params: reset_params(companies(:acme)),
           headers: auth_headers,
           as: :json

      _(response.status).must_equal 401
    end

    it "does not accept ADMIN_API_TOKEN" do
      ENV["ADMIN_API_TOKEN"] = "shared-admin-token"

      post admin_api_data_reset_url,
           params: reset_params(companies(:acme)),
           headers: auth_headers("shared-admin-token"),
           as: :json

      _(response.status).must_equal 401
    end
  end

  describe "targeting" do
    it "returns 404 when no company has that fluid_company_id" do
      post admin_api_data_reset_url,
           params: { fluid_company_id: 999_999_999, confirm: "nobody" },
           headers: auth_headers,
           as: :json

      _(response.status).must_equal 404
    end

    it "refuses when confirm does not match the company's fluid_shop" do
      company = companies(:acme)

      post admin_api_data_reset_url,
           params: reset_params(company, confirm: "globex_shop", dry_run: false),
           headers: auth_headers,
           as: :json

      _(response.status).must_equal 422
      _(company.events.count).must_be :>, 0
    end

    it "refuses when two installations share a fluid_company_id" do
      # `fluid_company_id` carries no unique index on this table — Rails never
      # added one. A reinstall can leave two rows for the same Fluid company,
      # and resetting one of them would clear half the data and report success.
      original = companies(:acme)
      Company.create!(
        name: "Acme (stale install)",
        fluid_shop: original.fluid_shop,
        authentication_token: "acme_token_stale",
        fluid_company_id: original.fluid_company_id,
        company_droplet_uuid: "acme-uuid-123",
        droplet_installation_uuid: "acme-installation-uuid-stale",
        active: false,
      )

      post admin_api_data_reset_url,
           params: reset_params(original, dry_run: false),
           headers: auth_headers,
           as: :json

      _(response.status).must_equal 409
      _(original.events.count).must_be :>, 0
    end
  end

  describe "the dry run" do
    it "is on when the body does not mention it" do
      company = companies(:acme)
      before_count = company.events.count
      _(before_count).must_be :>, 0

      post admin_api_data_reset_url,
           params: reset_params(company),
           headers: auth_headers,
           as: :json

      _(response.status).must_equal 200
      body = JSON.parse(response.body)
      _(body["dry_run"]).must_equal true
      _(body["deleted"]["events"]).must_equal before_count
      _(company.events.count).must_equal before_count
    end

    it "is off only when the body explicitly says false" do
      company = companies(:acme)
      _(company.events.count).must_be :>, 0

      post admin_api_data_reset_url,
           params: reset_params(company, dry_run: false),
           headers: auth_headers,
           as: :json

      _(response.status).must_equal 200
      _(JSON.parse(response.body)["dry_run"]).must_equal false
      _(company.events.count).must_equal 0
    end
  end

  describe "what it touches" do
    it "deletes only the target company's rows" do
      acme = companies(:acme)
      globex = companies(:globex)
      globex_before = globex.events.count

      post admin_api_data_reset_url,
           params: reset_params(acme, dry_run: false),
           headers: auth_headers,
           as: :json

      _(acme.events.count).must_equal 0
      _(globex.events.count).must_equal globex_before
    end

    it "keeps the installation and its configuration" do
      company = companies(:acme)
      company.create_integration_setting!(enabled: true, settings: { "a" => 1 }, credentials: { "user" => "x" })
      company.price_types.create!(name: "Preferred")

      post admin_api_data_reset_url,
           params: reset_params(company, dry_run: false),
           headers: auth_headers,
           as: :json

      _(Company.find_by(id: company.id)).wont_be_nil
      _(company.reload.integration_setting).wont_be_nil
      _(company.price_types.count).must_equal 1
    end

    it "reports the company, the counts and what it left alone" do
      company = companies(:acme)

      post admin_api_data_reset_url,
           params: reset_params(company, dry_run: false),
           headers: auth_headers,
           as: :json

      body = JSON.parse(response.body)
      _(body["company"]["id"]).must_equal company.id
      _(body["company"]["fluid_shop"]).must_equal company.fluid_shop
      _(body["deleted"]).must_be_kind_of Hash
      _(body["preserved"]).must_include "price_types"
      _(body["preserved"]).must_include "integration_settings"
      _(body["out_of_scope"]).must_include "callbacks"
    end
  end

  describe "cross-tenant safety" do
    # Populate every purged table for BOTH companies, then assert on GLOBAL row
    # counts rather than on `company.events.count`. An association count would
    # also read zero if the rows had merely been orphaned, and it can say
    # nothing at all about the other tenant's rows.
    def seed_all_tables(company, suffix)
      company.events.create!(
        identifier: "evt-#{suffix}", name: "order_completed",
        payload: { "a" => 1 }, timestamp: Time.current, status: 0,
      )
      company.cart_pricing_events.create!(cart_id: 1, event_type: "item_added")
      company.customer_type_transactions.create!(new_type: "preferred", source: "webhook")
      ExigoAutoshipSnapshot.create!(
        company: company, external_ids: [ "x-#{suffix}" ], synced_at: Time.current,
      )
      company.price_types.create!(name: "Preferred #{suffix}")
      company.create_integration_setting!(enabled: true, credentials: { "user" => suffix })
    end

    it "deletes the target's rows and leaves every other company's alone" do
      acme = companies(:acme)
      globex = companies(:globex)
      seed_all_tables(acme, "acme")
      seed_all_tables(globex, "globex")

      purged = [ Event, CartPricingEvent, CustomerTypeTransaction, ExigoAutoshipSnapshot ]
      globex_before = purged.to_h { |m| [ m, m.where(company_id: globex.id).count ] }
      globex_before.each_value { |count| _(count).must_be :>, 0 }

      post admin_api_data_reset_url,
           params: reset_params(acme, dry_run: false),
           headers: auth_headers,
           as: :json

      _(response.status).must_equal 200

      purged.each do |model|
        # Gone for the target — and really gone, not orphaned with a null FK.
        _(model.where(company_id: acme.id).count).must_equal 0
        # Untouched for everyone else.
        _(model.where(company_id: globex.id).count).must_equal globex_before[model]
        # And no row was left behind pointing at nothing.
        _(model.where(company_id: nil).count).must_equal 0
      end
    end

    it "leaves the other company's configuration alone too" do
      acme = companies(:acme)
      globex = companies(:globex)
      seed_all_tables(acme, "acme")
      seed_all_tables(globex, "globex")

      post admin_api_data_reset_url,
           params: reset_params(acme, dry_run: false),
           headers: auth_headers,
           as: :json

      _(PriceType.where(company_id: globex.id).count).must_equal 1
      _(IntegrationSetting.where(company_id: globex.id).count).must_equal 1
      # ...and the target's own configuration survives as well.
      _(PriceType.where(company_id: acme.id).count).must_equal 1
      _(IntegrationSetting.where(company_id: acme.id).count).must_equal 1
      _(Company.count).must_be :>=, 2
    end

    it "counts only the target's rows on a dry run" do
      acme = companies(:acme)
      globex = companies(:globex)
      seed_all_tables(acme, "acme")
      seed_all_tables(globex, "globex")
      acme_events = Event.where(company_id: acme.id).count
      total_events = Event.count
      _(total_events).must_be :>, acme_events

      post admin_api_data_reset_url,
           params: reset_params(acme),
           headers: auth_headers,
           as: :json

      _(JSON.parse(response.body)["deleted"]["events"]).must_equal acme_events
      _(Event.count).must_equal total_events
    end

    it "never touches the tables shared by every company" do
      # callbacks, webhooks, settings and users have no company_id at all: they
      # are global. Deleting from them would not just cross a tenant boundary,
      # it would break every tenant at once.
      acme = companies(:acme)
      seed_all_tables(acme, "acme")
      before = {
        Callback => Callback.count,
        Webhook => Webhook.count,
        Setting => Setting.count,
        User => User.count,
      }
      before.each_value { |count| _(count).must_be :>, 0 }

      post admin_api_data_reset_url,
           params: reset_params(acme, dry_run: false),
           headers: auth_headers,
           as: :json

      _(response.status).must_equal 200
      before.each { |model, count| _(model.count).must_equal count }
    end

    it "matches no company when fluid_company_id is absent" do
      # `Company.where(fluid_company_id: nil)` must not resolve to a tenant.
      post admin_api_data_reset_url,
           params: { confirm: "acme_shop", dry_run: false },
           headers: auth_headers,
           as: :json

      _(response.status).must_equal 404
    end
  end

  describe "the table classification" do
    it "covers every table in the schema" do
      schema = File.read(Rails.root.join("db/schema.rb"))
      tables = schema.scan(/create_table "([a-z_]+)"/).flatten
      _(tables).wont_be_empty

      classified =
        AdminApi::DataResetsController::PURGED_TABLES +
        AdminApi::DataResetsController::PRESERVED_TABLES +
        AdminApi::DataResetsController::OUT_OF_SCOPE_TABLES

      _(tables - classified).must_equal []
    end

    it "never classifies a table twice" do
      classified =
        AdminApi::DataResetsController::PURGED_TABLES +
        AdminApi::DataResetsController::PRESERVED_TABLES +
        AdminApi::DataResetsController::OUT_OF_SCOPE_TABLES

      _(classified.uniq).must_equal classified
    end

    it "treats the tables with no company_id as out of scope" do
      # A per-company reset cannot filter these, so it must not pretend to.
      _(AdminApi::DataResetsController::OUT_OF_SCOPE_TABLES).must_include "callbacks"
      _(AdminApi::DataResetsController::OUT_OF_SCOPE_TABLES).must_include "webhooks"
      _(AdminApi::DataResetsController::OUT_OF_SCOPE_TABLES).must_include "settings"
      _(AdminApi::DataResetsController::OUT_OF_SCOPE_TABLES).must_include "users"
      _(AdminApi::DataResetsController::OUT_OF_SCOPE_TABLES).must_include "fluid_callback_registrations"
    end
  end
end
