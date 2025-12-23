# frozen_string_literal: true

require "test_helper"

module Rain
  class CustomerSyncPageJobTest < ActiveJob::TestCase
    fixtures(:companies)

    def test_delegates_to_service
      company = companies(:acme)
      customers = [ { "id" => 101, "external_id" => "ext_101" } ]
      exigo_active_autoship_ids = [ "ext_101" ]
      preferred_type_id = "2"
      retail_type_id = "1"

      service_called = false
      service_args = nil

      mock_service = ->(**args) {
        service_args = args
        service_called = true
        Object.new.tap { |o| o.define_singleton_method(:call) { true } }
      }

      CustomerSyncPageService.stub(:new, mock_service) do
        CustomerSyncPageJob.perform_now(
          company_id: company.id,
          customers: customers,
          exigo_active_autoship_ids: exigo_active_autoship_ids,
          preferred_type_id: preferred_type_id,
          retail_type_id: retail_type_id
        )
      end

      assert service_called
      assert_equal company, service_args[:company]
      assert_equal customers, service_args[:customers]
      assert_equal exigo_active_autoship_ids, service_args[:exigo_active_autoship_ids]
      assert_equal preferred_type_id, service_args[:preferred_type_id]
      assert_equal retail_type_id, service_args[:retail_type_id]
    end

    def test_finds_company_by_id
      company = companies(:acme)
      customers = [ { "id" => 101, "external_id" => "ext_101" } ]

      found_company = nil
      mock_service = ->(**args) {
        found_company = args[:company]
        Object.new.tap { |o| o.define_singleton_method(:call) { true } }
      }

      CustomerSyncPageService.stub(:new, mock_service) do
        CustomerSyncPageJob.perform_now(
          company_id: company.id,
          customers: customers,
          exigo_active_autoship_ids: [],
          preferred_type_id: "2",
          retail_type_id: "1"
        )
      end

      assert_equal company.id, found_company.id
      assert_equal company.name, found_company.name
    end
  end
end
