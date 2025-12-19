# frozen_string_literal: true

require "test_helper"

module Rain
  class CustomerSyncPageServiceTest < ActiveSupport::TestCase
    fixtures(:companies)

    def test_demotes_customer_without_autoships
      company = companies(:acme)
      customers = [ { "id" => 101, "external_id" => "101" } ]

      metadata_calls = []
      exigo_update_calls = []

      fluid_client = build_fluid_client(
        active_autoship_proc: ->(_) { false },
        metadata_calls: metadata_calls
      )
      exigo_client = build_exigo_client(
        update_calls: exigo_update_calls
      )

      service = CustomerSyncPageService.new(
        company: company,
        customers: customers,
        exigo_active_autoship_ids: [],
        preferred_type_id: "2",
        retail_type_id: "1"
      )

      service.stub(:fluid_client, fluid_client) do
        service.stub(:exigo_client, exigo_client) do
          result = service.call
          assert_equal true, result
        end
      end

      assert_equal 1, metadata_calls.size
      assert_equal({ "customer_type" => "retail" }, metadata_calls.first[:value])
      assert_equal [ %w[101 1] ], exigo_update_calls
    end

    def test_keeps_preferred_when_exigo_autoship_is_active
      company = companies(:acme)
      customers = [ { "id" => 202, "external_id" => "202" } ]

      metadata_calls = []
      exigo_update_calls = []

      fluid_client = build_fluid_client(
        active_autoship_proc: ->(_) { false },
        metadata_calls: metadata_calls
      )
      exigo_client = build_exigo_client(
        update_calls: exigo_update_calls
      )

      service = CustomerSyncPageService.new(
        company: company,
        customers: customers,
        exigo_active_autoship_ids: [ "202" ],
        preferred_type_id: "2",
        retail_type_id: "1"
      )

      service.stub(:fluid_client, fluid_client) do
        service.stub(:exigo_client, exigo_client) do
          result = service.call
          assert_equal true, result
        end
      end

      assert_equal 1, metadata_calls.size
      assert_equal({ "customer_type" => "preferred_customer" }, metadata_calls.first[:value])
      assert_equal [ %w[202 2] ], exigo_update_calls
    end

    def test_keeps_preferred_when_fluid_autoship_is_active
      company = companies(:acme)
      customers = [ { "id" => 303, "external_id" => "303" } ]

      metadata_calls = []
      exigo_update_calls = []

      fluid_client = build_fluid_client(
        active_autoship_proc: ->(_) { true },
        metadata_calls: metadata_calls
      )
      exigo_client = build_exigo_client(
        update_calls: exigo_update_calls
      )

      service = CustomerSyncPageService.new(
        company: company,
        customers: customers,
        exigo_active_autoship_ids: [],
        preferred_type_id: "2",
        retail_type_id: "1"
      )

      service.stub(:fluid_client, fluid_client) do
        service.stub(:exigo_client, exigo_client) do
          result = service.call
          assert_equal true, result
        end
      end

      assert_equal 1, metadata_calls.size
      assert_equal({ "customer_type" => "preferred_customer" }, metadata_calls.first[:value])
      assert_equal [ %w[303 2] ], exigo_update_calls
    end

    def test_processes_multiple_customers
      company = companies(:acme)
      customers = [
        { "id" => 101, "external_id" => "101" },
        { "id" => 102, "external_id" => "102" },
      ]

      metadata_calls = []
      exigo_update_calls = []

      fluid_client = build_fluid_client(
        active_autoship_proc: ->(_) { false },
        metadata_calls: metadata_calls
      )
      exigo_client = build_exigo_client(
        update_calls: exigo_update_calls
      )

      service = CustomerSyncPageService.new(
        company: company,
        customers: customers,
        exigo_active_autoship_ids: [],
        preferred_type_id: "2",
        retail_type_id: "1"
      )

      service.stub(:fluid_client, fluid_client) do
        service.stub(:exigo_client, exigo_client) do
          result = service.call
          assert_equal true, result
        end
      end

      assert_equal 2, metadata_calls.size
      assert_equal 2, exigo_update_calls.size
    end

    def test_continues_when_one_customer_fails
      company = companies(:acme)
      customers = [
        { "id" => 101, "external_id" => "101" },
        { "id" => 102, "external_id" => "102" },
      ]

      call_count = 0
      metadata_calls = []

      fluid_client = build_fluid_client(
        active_autoship_proc: ->(_) { false },
        metadata_calls: metadata_calls,
        metafields_update_proc: ->(args) {
          call_count += 1
          raise FluidClient::Error, "API Error" if call_count == 1
          metadata_calls << args
        }
      )
      exigo_client = build_exigo_client(update_calls: [])

      service = CustomerSyncPageService.new(
        company: company,
        customers: customers,
        exigo_active_autoship_ids: [],
        preferred_type_id: "2",
        retail_type_id: "1"
      )

      service.stub(:fluid_client, fluid_client) do
        service.stub(:exigo_client, exigo_client) do
          result = service.call
          assert_equal true, result
        end
      end

      assert_equal 1, metadata_calls.size
    end

    def test_skips_customer_without_external_id
      company = companies(:acme)
      customers = [ { "id" => 101, "external_id" => nil } ]

      metadata_calls = []

      fluid_client = build_fluid_client(
        active_autoship_proc: ->(_) { false },
        metadata_calls: metadata_calls
      )
      exigo_client = build_exigo_client(update_calls: [])

      service = CustomerSyncPageService.new(
        company: company,
        customers: customers,
        exigo_active_autoship_ids: [],
        preferred_type_id: "2",
        retail_type_id: "1"
      )

      service.stub(:fluid_client, fluid_client) do
        service.stub(:exigo_client, exigo_client) do
          result = service.call
          assert_equal true, result
        end
      end

      assert_equal [], metadata_calls
    end

  private

    def build_fluid_client(active_autoship_proc:, metadata_calls:, metafields_update_proc: nil)
      customers_resource = Class.new do
        define_method(:active_autoship?, &active_autoship_proc)
      end.new

      calls = metadata_calls
      update_proc = metafields_update_proc
      metafields_resource = Class.new do
        define_method(:ensure_definition) { |_args| true }
        define_method(:update) do |**args|
          update_proc ? update_proc.call(args) : calls << args
        end
        define_method(:create) { |**args| calls << args }
      end.new

      Class.new do
        define_method(:customers) { customers_resource }
        define_method(:metafields) { metafields_resource }
      end.new
    end

    def build_exigo_client(update_calls:)
      calls = update_calls
      Class.new do
        define_method(:update_customer_type) { |id, type_id| calls << [ id, type_id ] }
      end.new
    end
  end
end
