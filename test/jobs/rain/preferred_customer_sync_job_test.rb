require "test_helper"

module Rain
  class PreferredCustomerSyncJobTest < ActiveJob::TestCase
    def test_demotes_when_no_autoships_in_exigo_or_fluid
      company = companies(:acme)
      ENV["RAIN_FLUID_COMPANY_ID"] = company.fluid_company_id.to_s
      ENV["RAIN_PREFERRED_CUSTOMER_TYPE_ID"] = "2"
      ENV["RAIN_RETAIL_CUSTOMER_TYPE_ID"] = "1"

      metadata_calls = []
      fluid_customers_resource = build_fluid_resource(
        customers: [ { "id" => 101 } ],
        active_autoship_proc: ->(_) { false },
        metadata_calls: metadata_calls
      )

      job = PreferredCustomerSyncJob.new

      job.stub(:exigo_client, build_exigo_client([], ->(_) { false })) do
        job.stub(:fluid_client, build_fluid_client(fluid_customers_resource)) do
          perform_enqueued_jobs { job.perform }
        end
      end

      assert_equal [ [ 101, { "customer_type" => "retail" } ] ], metadata_calls
    end

    def test_keeps_preferred_when_exigo_autoship_is_active
      company = companies(:acme)
      ENV["RAIN_FLUID_COMPANY_ID"] = company.fluid_company_id.to_s
      ENV["RAIN_PREFERRED_CUSTOMER_TYPE_ID"] = "2"
      ENV["RAIN_RETAIL_CUSTOMER_TYPE_ID"] = "1"

      metadata_calls = []
      fluid_customers_resource = build_fluid_resource(
        customers: [ { "id" => 202 } ],
        active_autoship_proc: ->(_) { false },
        metadata_calls: metadata_calls
      )

      job = PreferredCustomerSyncJob.new

      job.stub(:exigo_client, build_exigo_client([ 202 ], ->(_) { true })) do
        job.stub(:fluid_client, build_fluid_client(fluid_customers_resource)) do
          perform_enqueued_jobs { job.perform }
        end
      end

      assert_equal [ [ 202, { "customer_type" => "preferred_customer" } ] ], metadata_calls
    end

    def test_keeps_preferred_when_fluid_autoship_is_active
      company = companies(:acme)
      ENV["RAIN_FLUID_COMPANY_ID"] = company.fluid_company_id.to_s
      ENV["RAIN_PREFERRED_CUSTOMER_TYPE_ID"] = "2"
      ENV["RAIN_RETAIL_CUSTOMER_TYPE_ID"] = "1"

      metadata_calls = []
      fluid_customers_resource = build_fluid_resource(
        customers: [ { "id" => 303 } ],
        active_autoship_proc: ->(_) { true },
        metadata_calls: metadata_calls
      )

      job = PreferredCustomerSyncJob.new

      job.stub(:exigo_client, build_exigo_client([], ->(_) { false })) do
        job.stub(:fluid_client, build_fluid_client(fluid_customers_resource)) do
          perform_enqueued_jobs { job.perform }
        end
      end

      assert_equal [], metadata_calls
    end

  private

    def build_exigo_client(active_autoship_ids, has_autoship_proc)
      Class.new do
        define_method(:customers_with_active_autoships) { active_autoship_ids }
        define_method(:customer_has_active_autoship?, &has_autoship_proc)
      end.new
    end

    def build_fluid_resource(customers:, active_autoship_proc:, metadata_calls:)
      Class.new do
        define_method(:get) { |_params = nil| { "customers" => customers } }
        define_method(:active_autoship?, &active_autoship_proc)
        define_method(:append_metadata) { |id, payload| metadata_calls << [ id, payload ] }
      end.new
    end

    def build_fluid_client(resource)
      Class.new do
        define_method(:customers) { resource }
      end.new
    end
  end
end
