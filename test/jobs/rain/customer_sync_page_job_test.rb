# frozen_string_literal: true

require "test_helper"

module Rain
  class CustomerSyncPageJobTest < ActiveJob::TestCase
    fixtures(:companies)

    def test_processes_batch_of_customers
      company = companies(:acme)
      customers = [
        { "id" => 101, "external_id" => "ext_101" },
        { "id" => 102, "external_id" => "ext_102" },
      ]

      processed_customers = []
      fluid_client_stub = build_fluid_client(
        active_autoship_proc: ->(_) { false },
        metafield_update_proc: ->(args) { processed_customers << args[:resource_id] }
      )

      exigo_client_stub = build_exigo_client(
        update_proc: ->(_id, _type) { }
      )

      job = CustomerSyncPageJob.new
      job.stub(:fluid_client, fluid_client_stub) do
        job.stub(:exigo_client, exigo_client_stub) do
          job.perform(
            company_id: company.id,
            customers: customers,
            exigo_active_autoship_ids: [],
            preferred_type_id: "2",
            retail_type_id: "1"
          )
        end
      end

      assert_equal [ 101, 102 ], processed_customers
    end

    def test_keeps_customer_as_preferred_when_has_exigo_autoship
      company = companies(:acme)
      customers = [ { "id" => 101, "external_id" => "ext_101" } ]

      customer_types = []
      fluid_client_stub = build_fluid_client(
        active_autoship_proc: ->(_) { false },
        metafield_update_proc: ->(args) { customer_types << args[:value]["customer_type"] }
      )

      exigo_client_stub = build_exigo_client(update_proc: ->(_id, _type) { })

      job = CustomerSyncPageJob.new
      job.stub(:fluid_client, fluid_client_stub) do
        job.stub(:exigo_client, exigo_client_stub) do
          job.perform(
            company_id: company.id,
            customers: customers,
            exigo_active_autoship_ids: [ "ext_101" ],
            preferred_type_id: "2",
            retail_type_id: "1"
          )
        end
      end

      assert_equal [ "preferred_customer" ], customer_types
    end

    def test_keeps_customer_when_has_fluid_autoship
      company = companies(:acme)
      customers = [ { "id" => 101, "external_id" => "ext_101" } ]

      metafield_calls = []
      fluid_client_stub = build_fluid_client(
        active_autoship_proc: ->(_) { true },
        metafield_update_proc: ->(args) { metafield_calls << args }
      )

      exigo_client_stub = build_exigo_client(update_proc: ->(_id, _type) { })

      job = CustomerSyncPageJob.new
      job.stub(:fluid_client, fluid_client_stub) do
        job.stub(:exigo_client, exigo_client_stub) do
          job.perform(
            company_id: company.id,
            customers: customers,
            exigo_active_autoship_ids: [],
            preferred_type_id: "2",
            retail_type_id: "1"
          )
        end
      end

      assert_empty metafield_calls
    end

    def test_demotes_customer_to_retail_when_no_autoships
      company = companies(:acme)
      customers = [ { "id" => 101, "external_id" => "ext_101" } ]

      customer_types = []
      fluid_client_stub = build_fluid_client(
        active_autoship_proc: ->(_) { false },
        metafield_update_proc: ->(args) { customer_types << args[:value]["customer_type"] }
      )

      exigo_client_stub = build_exigo_client(update_proc: ->(_id, _type) { })

      job = CustomerSyncPageJob.new
      job.stub(:fluid_client, fluid_client_stub) do
        job.stub(:exigo_client, exigo_client_stub) do
          job.perform(
            company_id: company.id,
            customers: customers,
            exigo_active_autoship_ids: [],
            preferred_type_id: "2",
            retail_type_id: "1"
          )
        end
      end

      assert_equal [ "retail" ], customer_types
    end

    def test_continues_processing_when_one_customer_fails
      company = companies(:acme)
      customers = [
        { "id" => 101, "external_id" => "ext_101" },
        { "id" => 102, "external_id" => "ext_102" },
      ]

      processed_ids = []
      call_count = 0
      fluid_client_stub = build_fluid_client(
        active_autoship_proc: ->(_) { false },
        metafield_update_proc: ->(args) {
          call_count += 1
          raise StandardError, "API Error" if call_count == 1
          processed_ids << args[:resource_id]
        }
      )

      exigo_client_stub = build_exigo_client(update_proc: ->(_id, _type) { })

      job = CustomerSyncPageJob.new
      job.stub(:fluid_client, fluid_client_stub) do
        job.stub(:exigo_client, exigo_client_stub) do
          job.perform(
            company_id: company.id,
            customers: customers,
            exigo_active_autoship_ids: [],
            preferred_type_id: "2",
            retail_type_id: "1"
          )
        end
      end

      assert_equal [ 102 ], processed_ids
    end

    def test_skips_customers_without_external_id
      company = companies(:acme)
      customers = [
        { "id" => 101, "external_id" => nil },
        { "id" => 102, "external_id" => "ext_102" },
      ]

      processed_ids = []
      fluid_client_stub = build_fluid_client(
        active_autoship_proc: ->(_) { false },
        metafield_update_proc: ->(args) { processed_ids << args[:resource_id] }
      )

      exigo_client_stub = build_exigo_client(update_proc: ->(_id, _type) { })

      job = CustomerSyncPageJob.new
      job.stub(:fluid_client, fluid_client_stub) do
        job.stub(:exigo_client, exigo_client_stub) do
          job.perform(
            company_id: company.id,
            customers: customers,
            exigo_active_autoship_ids: [],
            preferred_type_id: "2",
            retail_type_id: "1"
          )
        end
      end

      assert_equal [ 102 ], processed_ids
    end

    def test_updates_exigo_customer_type
      company = companies(:acme)
      customers = [ { "id" => 101, "external_id" => "ext_101" } ]

      exigo_updates = []
      fluid_client_stub = build_fluid_client(
        active_autoship_proc: ->(_) { false },
        metafield_update_proc: ->(_) { }
      )

      exigo_client_stub = build_exigo_client(
        update_proc: ->(id, type) { exigo_updates << [ id, type ] }
      )

      job = CustomerSyncPageJob.new
      job.stub(:fluid_client, fluid_client_stub) do
        job.stub(:exigo_client, exigo_client_stub) do
          job.perform(
            company_id: company.id,
            customers: customers,
            exigo_active_autoship_ids: [],
            preferred_type_id: "2",
            retail_type_id: "1"
          )
        end
      end

      assert_equal [ %w[ext_101 1] ], exigo_updates
    end

  private

    def build_fluid_client(active_autoship_proc:, metafield_update_proc:)
      customers_resource = Class.new do
        define_method(:active_autoship?, &active_autoship_proc)
      end.new

      metafields_resource = Class.new do
        define_method(:ensure_definition) { |_| nil }
        define_method(:update, &metafield_update_proc)
        define_method(:create, &metafield_update_proc)
      end.new

      Class.new do
        define_method(:customers) { customers_resource }
        define_method(:metafields) { metafields_resource }
      end.new
    end

    def build_exigo_client(update_proc:)
      Class.new do
        define_method(:update_customer_type, &update_proc)
      end.new
    end
  end
end
