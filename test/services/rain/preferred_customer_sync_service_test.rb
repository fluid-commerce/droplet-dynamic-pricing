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

    def test_returns_false_when_exigo_fetch_fails
      company = companies(:acme)
      exigo_client_stub = Class.new do
        def customers_with_active_autoships
          raise ExigoClient::Error, "Database connection failed"
        end
      end.new

      service = PreferredCustomerSyncService.new(company: company)

      service.stub(:exigo_client, exigo_client_stub) do
        result = service.call
        assert_equal(false, result)
      end
    end

    def test_returns_true_when_no_autoships
      company = companies(:acme)
      exigo_client_stub = build_exigo_client(active_autoship_ids: [])
      fluid_client_stub = build_fluid_client(customers: [])

      service = PreferredCustomerSyncService.new(company: company)

      service.stub(:exigo_client, exigo_client_stub) do
        service.stub(:fluid_client, fluid_client_stub) do
          result = service.call
          assert_equal(true, result)
        end
      end

      snapshot = ExigoAutoshipSnapshot.latest_for_company(company)
      assert_not_nil(snapshot)
      assert_equal([], snapshot.external_ids)
    end

    def test_saves_snapshot_after_sync
      company = companies(:acme)
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
      ExigoAutoshipSnapshot.create!(
        company: company,
        external_ids: %w[101],
        synced_at: 1.day.ago
      )

      exigo_client_stub = build_exigo_client(active_autoship_ids: [])
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

  private

    def build_exigo_client(active_autoship_ids:, customer_types: {})
      Class.new do
        define_method(:customers_with_active_autoships) { active_autoship_ids }
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
