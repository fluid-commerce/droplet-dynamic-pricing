# frozen_string_literal: true

require "test_helper"

module Rain
  class PreferredCustomerSyncServiceTest < ActiveSupport::TestCase
    fixtures(:companies)

    def test_validates_company_parameter
      assert_raises(ArgumentError, "company must be a Company") do
        PreferredCustomerSyncService.new(company: nil)
      end

      assert_raises(ArgumentError, "company must be a Company") do
        PreferredCustomerSyncService.new(company: "not a company")
      end
    end

    def test_raises_error_when_exigo_integration_not_enabled
      company = companies(:acme)
      # No integration_setting created

      assert_raises(ArgumentError, "Exigo integration not enabled") do
        PreferredCustomerSyncService.new(company: company)
      end
    end

    def test_raises_error_when_integration_setting_disabled
      company = companies(:acme)
      IntegrationSetting.create!(
        company: company,
        enabled: false,
        credentials: {},
        settings: {}
      )

      assert_raises(ArgumentError, "Exigo integration not enabled") do
        PreferredCustomerSyncService.new(company: company)
      end
    end

    def test_returns_false_when_exigo_fetch_fails
      company = companies(:acme)
      create_integration_setting(company: company)
      exigo_client_stub = Class.new do
        def customers_with_active_autoships
          raise ExigoClient::Error, "Database connection failed"
        end
      end.new
      fluid_client_stub = build_fluid_client(customers: [])

      service = PreferredCustomerSyncService.new(company: company)

      service.stub(:exigo_client, exigo_client_stub) do
        service.stub(:fluid_client, fluid_client_stub) do
          result = service.call
          assert_equal(false, result)
        end
      end
    end

    def test_saves_snapshot_after_sync
      company = companies(:acme)
      create_integration_setting(company: company)
      exigo_client_stub = build_exigo_client(active_autoship_ids: %w[101 102 103])
      fluid_client_stub = build_fluid_client(customers: [])

      service = PreferredCustomerSyncService.new(company: company)

      service.stub(:exigo_client, exigo_client_stub) do
        service.stub(:fluid_client, fluid_client_stub) do
          service.call
        end
      end

      snapshot = ExigoAutoshipSnapshot.latest_for_company(company)
      assert_not_nil(snapshot)
      assert_equal(%w[101 102 103], snapshot.external_ids)
    end

    def test_detects_new_autoships
      company = companies(:acme)
      create_integration_setting(company: company)
      ExigoAutoshipSnapshot.create!(
        company: company,
        external_ids: %w[101],
        synced_at: 1.day.ago
      )

      exigo_client_stub = build_exigo_client(active_autoship_ids: %w[101 102])
      customer_102 = { "id" => 102, "external_id" => "102", "metadata" => {} }
      fluid_client_stub = build_fluid_client(
        customers: [ customer_102 ],
        metafields_updated: [],
        metadata_updated: []
      )

      service = PreferredCustomerSyncService.new(company: company)

      service.stub(:exigo_client, exigo_client_stub) do
        service.stub(:fluid_client, fluid_client_stub) do
          result = service.call
          assert_equal(true, result)
        end
      end
    end

    def test_detects_lost_autoships
      company = companies(:acme)
      create_integration_setting(company: company)
      ExigoAutoshipSnapshot.create!(
        company: company,
        external_ids: %w[101 102],
        synced_at: 1.day.ago
      )

      exigo_client_stub = build_exigo_client(active_autoship_ids: %w[101])
      customer_102 = {
        "id" => 102,
        "external_id" => "102",
        "metadata" => { "customer_type" => "preferred_customer" },
      }
      fluid_client_stub = build_fluid_client(
        customers: [ customer_102 ],
        subscriptions: []
      )

      service = PreferredCustomerSyncService.new(company: company)

      service.stub(:exigo_client, exigo_client_stub) do
        service.stub(:fluid_client, fluid_client_stub) do
          result = service.call
          assert_equal(true, result)
        end
      end
    end

    def test_keeps_preferred_if_has_fluid_subscription
      company = companies(:acme)
      create_integration_setting(company: company)
      ExigoAutoshipSnapshot.create!(
        company: company,
        external_ids: %w[101 102],
        synced_at: 1.day.ago
      )

      exigo_client_stub = build_exigo_client(active_autoship_ids: %w[102])

      customer_101 = {
        "id" => 101,
        "external_id" => "101",
        "metadata" => { "customer_type" => "preferred_customer" },
      }
      fluid_client_stub = build_fluid_client(
        customers: [ customer_101 ],
        subscriptions: [ { "id" => 1, "status" => "active" } ]
      )

      service = PreferredCustomerSyncService.new(company: company)

      service.stub(:exigo_client, exigo_client_stub) do
        service.stub(:fluid_client, fluid_client_stub) do
          result = service.call
          assert_equal(true, result)
        end
      end
    end

    # The default has to be byte-identical to today: an IntegrationSetting with
    # no exigo_preferred_signal key must still read autoships and must not
    # touch the customer-type query at all.
    def test_defaults_to_reading_active_autoships
      company = companies(:acme)
      create_integration_setting(company: company)
      calls = []
      exigo_client_stub = build_exigo_client(active_autoship_ids: %w[101 102], calls: calls)
      fluid_client_stub = build_fluid_client(customers: [])

      service = PreferredCustomerSyncService.new(company: company)

      service.stub(:exigo_client, exigo_client_stub) do
        service.stub(:fluid_client, fluid_client_stub) do
          service.call
        end
      end

      assert_equal [ :customers_with_active_autoships ], calls
      assert_equal %w[101 102], ExigoAutoshipSnapshot.latest_for_company(company).external_ids
    end

    def test_customer_type_signal_reads_ids_by_customer_type
      company = companies(:acme)
      create_integration_setting(
        company: company,
        settings: { "exigo_preferred_signal" => "customer_type" }
      )
      calls = []
      exigo_client_stub = build_exigo_client(
        active_autoship_ids: %w[999],
        ids_by_type: { "2" => [ 201, 202 ] },
        calls: calls
      )
      fluid_client_stub = build_fluid_client(customers: [])

      service = PreferredCustomerSyncService.new(company: company)

      service.stub(:exigo_client, exigo_client_stub) do
        service.stub(:fluid_client, fluid_client_stub) do
          service.call
        end
      end

      assert_equal [ [ :customers_by_type_id, "2" ] ], calls
      assert_equal %w[201 202], ExigoAutoshipSnapshot.latest_for_company(company).external_ids
    end

    def test_customer_type_signal_uses_the_configured_type_id
      company = companies(:acme)
      create_integration_setting(
        company: company,
        settings: {
          "exigo_preferred_signal" => "customer_type",
          "preferred_customer_type_id" => "7",
        }
      )
      calls = []
      exigo_client_stub = build_exigo_client(
        active_autoship_ids: [],
        ids_by_type: { "7" => [ 301 ] },
        calls: calls
      )
      fluid_client_stub = build_fluid_client(customers: [])

      service = PreferredCustomerSyncService.new(company: company)

      service.stub(:exigo_client, exigo_client_stub) do
        service.stub(:fluid_client, fluid_client_stub) do
          service.call
        end
      end

      assert_equal [ [ :customers_by_type_id, "7" ] ], calls
      assert_equal %w[301], ExigoAutoshipSnapshot.latest_for_company(company).external_ids
    end

    # The customer-type read has to fail the same way the autoship read does:
    # abandon the sync rather than write an empty snapshot, which would demote
    # every preferred customer on the next delta.
    def test_returns_false_when_the_customer_type_fetch_fails
      company = companies(:acme)
      create_integration_setting(
        company: company,
        settings: { "exigo_preferred_signal" => "customer_type" }
      )
      exigo_client_stub = Class.new do
        def customers_by_type_id(_type_id)
          raise ExigoClient::Error, "Database connection failed"
        end
      end.new
      fluid_client_stub = build_fluid_client(customers: [])

      service = PreferredCustomerSyncService.new(company: company)

      service.stub(:exigo_client, exigo_client_stub) do
        service.stub(:fluid_client, fluid_client_stub) do
          assert_equal(false, service.call)
        end
      end
    end

  private

    def create_integration_setting(company:, settings: {})
      IntegrationSetting.create!(
        company: company,
        enabled: true,
        credentials: {
          exigo_db_host: "db.example.com",
          exigo_db_username: "user",
          exigo_db_password: "pass",
          exigo_db_name: "exigo_db",
          api_base_url: "https://api.example.com",
          api_username: "api_user",
          api_password: "api_pass",
        },
        settings: settings
      )
    end

    def build_exigo_client(active_autoship_ids:, customer_types: {}, ids_by_type: {}, calls: [])
      Class.new do
        define_method(:customers_with_active_autoships) do
          calls << :customers_with_active_autoships
          active_autoship_ids
        end
        define_method(:customers_by_type_id) do |type_id|
          calls << [ :customers_by_type_id, type_id ]
          ids_by_type[type_id.to_s] || []
        end
        define_method(:get_customer_type) { |id| customer_types[id.to_s] }
        define_method(:update_customer_type) { |_id, _type| true }
      end.new
    end

    def build_fluid_client(customers: [], subscriptions: [], metafields_updated: [], metadata_updated: [])
      filtered_customers = customers
      customers_resource = Class.new do
        define_method(:get) do |params = {}|
          matched = filtered_customers.select { |c| c["external_id"].to_s == params[:search_query].to_s }
          { "customers" => matched }
        end
        define_method(:append_metadata) { |id, data| metadata_updated << { id: id, data: data } }
      end.new

      subscriptions_resource = Class.new do
        define_method(:get_by_customer) { |_id, _opts = {}| { "subscriptions" => subscriptions } }
      end.new

      metafields_resource = Class.new do
        define_method(:ensure_definition) { |**_args| true }
        define_method(:update) { |**args| metafields_updated << args }
      end.new

      Class.new do
        define_method(:customers) { customers_resource }
        define_method(:subscriptions) { subscriptions_resource }
        define_method(:metafields) { metafields_resource }
      end.new
    end
  end
end
