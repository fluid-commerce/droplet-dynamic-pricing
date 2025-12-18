require "test_helper"

module Rain
  class PreferredCustomerSyncServiceTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper
    fixtures(:companies)

    def test_enqueues_page_job_for_customers
      company = companies(:acme)
      ENV["RAIN_PREFERRED_CUSTOMER_TYPE_ID"] = "2"
      ENV["RAIN_RETAIL_CUSTOMER_TYPE_ID"] = "1"

      fluid_customers_resource = build_fluid_resource(
        customers: [ { "id" => 101, "external_id" => "101" } ]
      )

      exigo_client_stub = build_exigo_client(active_autoship_ids: [])
      service = PreferredCustomerSyncService.new(company: company)

      service.stub(:exigo_client, exigo_client_stub) do
        service.stub(:fluid_client, build_fluid_client(fluid_customers_resource)) do
          assert_enqueued_with(job: Rain::CustomerSyncPageJob) do
            result = service.call
            assert_equal(true, result)
          end
        end
      end
    end

    def test_enqueues_job_with_correct_arguments
      company = companies(:acme)
      ENV["RAIN_PREFERRED_CUSTOMER_TYPE_ID"] = "2"
      ENV["RAIN_RETAIL_CUSTOMER_TYPE_ID"] = "1"

      customers = [ { "id" => 202, "external_id" => "202" } ]
      fluid_customers_resource = build_fluid_resource(customers: customers)

      exigo_client_stub = build_exigo_client(active_autoship_ids: [ "202" ])
      service = PreferredCustomerSyncService.new(company: company)

      service.stub(:exigo_client, exigo_client_stub) do
        service.stub(:fluid_client, build_fluid_client(fluid_customers_resource)) do
          result = service.call
          assert_equal(true, result)

          enqueued_jobs = ActiveJob::Base.queue_adapter.enqueued_jobs
          job = enqueued_jobs.find { |j| j["job_class"] == "Rain::CustomerSyncPageJob" }
          assert_not_nil job

          args = job["arguments"].first
          assert_equal company.id, args["company_id"]
          assert_equal 202, args["customers"].first["id"]
          assert_equal "202", args["customers"].first["external_id"]
          assert_equal [ "202" ], args["exigo_active_autoship_ids"]
          assert_equal "2", args["preferred_type_id"]
          assert_equal "1", args["retail_type_id"]
        end
      end
    end

    def test_validates_company_parameter
      assert_raises(ArgumentError, "company must be a Company") do
        PreferredCustomerSyncService.new(company: nil)
      end

      assert_raises(ArgumentError, "company must be a Company") do
        PreferredCustomerSyncService.new(company: "not a company")
      end
    end

    def test_aborts_when_exigo_autoships_fetch_fails
      company = companies(:acme)
      ENV["RAIN_PREFERRED_CUSTOMER_TYPE_ID"] = "2"
      ENV["RAIN_RETAIL_CUSTOMER_TYPE_ID"] = "1"

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

    def test_enqueues_multiple_page_jobs
      company = companies(:acme)
      ENV["RAIN_PREFERRED_CUSTOMER_TYPE_ID"] = "2"
      ENV["RAIN_RETAIL_CUSTOMER_TYPE_ID"] = "1"

      page1_customers = (1..100).map { |i| { "id" => i, "external_id" => i.to_s } }
      page2_customers = (101..150).map { |i| { "id" => i, "external_id" => i.to_s } }

      fluid_customers_resource = build_paginated_fluid_resource(
        pages: [ page1_customers, page2_customers ]
      )

      exigo_client_stub = build_exigo_client(active_autoship_ids: [])
      service = PreferredCustomerSyncService.new(company: company)

      service.stub(:exigo_client, exigo_client_stub) do
        service.stub(:fluid_client, build_fluid_client(fluid_customers_resource)) do
          result = service.call
          assert_equal(true, result)

          enqueued_jobs = ActiveJob::Base.queue_adapter.enqueued_jobs
          page_jobs = enqueued_jobs.select { |j| j["job_class"] == "Rain::CustomerSyncPageJob" }
          assert_equal 2, page_jobs.size
        end
      end
    end

    def test_returns_true_when_no_customers
      company = companies(:acme)
      ENV["RAIN_PREFERRED_CUSTOMER_TYPE_ID"] = "2"
      ENV["RAIN_RETAIL_CUSTOMER_TYPE_ID"] = "1"

      fluid_customers_resource = build_fluid_resource(customers: [])
      exigo_client_stub = build_exigo_client(active_autoship_ids: [])
      service = PreferredCustomerSyncService.new(company: company)

      service.stub(:exigo_client, exigo_client_stub) do
        service.stub(:fluid_client, build_fluid_client(fluid_customers_resource)) do
          result = service.call
          assert_equal(true, result)
        end
      end
    end

  private

    def build_exigo_client(active_autoship_ids:)
      Class.new do
        define_method(:customers_with_active_autoships) { active_autoship_ids }
      end.new
    end

    def build_fluid_resource(customers:)
      Class.new do
        define_method(:get) { |_params = nil| { "customers" => customers } }
      end.new
    end

    def build_paginated_fluid_resource(pages:)
      page_index = 0
      Class.new do
        define_method(:get) do |params = {}|
          current_page = page_index
          page_index += 1
          { "customers" => pages[current_page] || [] }
        end
      end.new
    end

    def build_fluid_client(resource)
      Class.new do
        define_method(:customers) { resource }
      end.new
    end
  end
end
