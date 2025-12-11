require "test_helper"

module Rain
  class PreferredCustomerSyncServiceTest < ActiveSupport::TestCase
    fixtures(:companies)

    def test_demotes_when_no_autoships_in_exigo_or_fluid
      company = companies(:acme)
      ENV["RAIN_PREFERRED_CUSTOMER_TYPE_ID"] = "2"
      ENV["RAIN_RETAIL_CUSTOMER_TYPE_ID"] = "1"

      metadata_calls = []
      fluid_customers_resource = build_fluid_resource(
        customers: [ { "id" => 101 } ],
        active_autoship_proc: ->(_) { false },
        metadata_calls: metadata_calls
      )

      exigo_update_calls = []
      exigo_client_stub = build_exigo_client(
        active_autoship_ids: [],
        has_autoship_proc: ->(_) { false },
        update_customer_type_proc: ->(id, type_id) { exigo_update_calls << [ id, type_id ] }
      )

      service = PreferredCustomerSyncService.new(company: company)

      service.stub(:exigo_client, exigo_client_stub) do
        service.stub(:fluid_client, build_fluid_client(fluid_customers_resource, metadata_calls: metadata_calls)) do
          result = service.call
          assert_equal(true, result)
        end
      end

      assert_equal 1, metadata_calls.size
      op, args = metadata_calls.first
      assert_equal :update, op
      assert_equal 101, args[:resource_id]
      assert_equal({ "customer_type" => "retail" }, args[:value])
      assert_equal [ [ 101, "1" ] ], exigo_update_calls
    end

    def test_keeps_preferred_when_exigo_autoship_is_active
      company = companies(:acme)
      ENV["RAIN_PREFERRED_CUSTOMER_TYPE_ID"] = "2"
      ENV["RAIN_RETAIL_CUSTOMER_TYPE_ID"] = "1"

      metadata_calls = []
      fluid_customers_resource = build_fluid_resource(
        customers: [ { "id" => 202 } ],
        active_autoship_proc: ->(_) { false },
        metadata_calls: metadata_calls
      )

      exigo_update_calls = []
      exigo_client_stub = build_exigo_client(
        active_autoship_ids: [ 202 ],
        has_autoship_proc: ->(_) { true },
        update_customer_type_proc: ->(id, type_id) { exigo_update_calls << [ id, type_id ] }
      )

      service = PreferredCustomerSyncService.new(company: company)

      service.stub(:exigo_client, exigo_client_stub) do
        service.stub(:fluid_client, build_fluid_client(fluid_customers_resource, metadata_calls: metadata_calls)) do
          result = service.call
          assert_equal(true, result)
        end
      end

      assert_equal 1, metadata_calls.size
      op, args = metadata_calls.first
      assert_equal :update, op
      assert_equal 202, args[:resource_id]
      assert_equal({ "customer_type" => "preferred_customer" }, args[:value])
      assert_equal [ [ 202, "2" ] ], exigo_update_calls
    end

    def test_keeps_preferred_when_fluid_autoship_is_active
      company = companies(:acme)
      ENV["RAIN_PREFERRED_CUSTOMER_TYPE_ID"] = "2"
      ENV["RAIN_RETAIL_CUSTOMER_TYPE_ID"] = "1"

      metadata_calls = []
      fluid_customers_resource = build_fluid_resource(
        customers: [ { "id" => 303 } ],
        active_autoship_proc: ->(_) { true },
        metadata_calls: metadata_calls
      )

      exigo_update_calls = []
      exigo_client_stub = build_exigo_client(
        active_autoship_ids: [],
        has_autoship_proc: ->(_) { false },
        update_customer_type_proc: ->(id, type_id) { exigo_update_calls << [ id, type_id ] }
      )

      service = PreferredCustomerSyncService.new(company: company)

      service.stub(:exigo_client, exigo_client_stub) do
        service.stub(:fluid_client, build_fluid_client(fluid_customers_resource, metadata_calls: metadata_calls)) do
          result = service.call
          assert_equal(true, result)
        end
      end

      assert_equal [], metadata_calls
      assert_equal [], exigo_update_calls
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

      # Mock ExigoClient to raise error on customers_with_active_autoships
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

    def test_skips_customer_when_individual_exigo_check_fails
      company = companies(:acme)
      ENV["RAIN_PREFERRED_CUSTOMER_TYPE_ID"] = "2"
      ENV["RAIN_RETAIL_CUSTOMER_TYPE_ID"] = "1"

      metadata_calls = []
      fluid_customers_resource = build_fluid_resource(
        customers: [ { "id" => 101 }, { "id" => 102 } ],
        active_autoship_proc: ->(_) { false },
        metadata_calls: metadata_calls
      )

      # Mock ExigoClient where customer_has_active_autoship? fails for customer 101
      exigo_client_stub = Class.new do
        def customers_with_active_autoships
          []
        end

        def customer_has_active_autoship?(customer_id)
          if customer_id == 101
            raise ExigoClient::Error, "Query timeout"
          end
          false
        end

        def update_customer_type(customer_id, customer_type_id)
          # No-op for test
        end
      end.new

      service = PreferredCustomerSyncService.new(company: company)

      service.stub(:exigo_client, exigo_client_stub) do
        service.stub(:fluid_client, build_fluid_client(fluid_customers_resource, metadata_calls: metadata_calls)) do
          result = service.call
          assert_equal(true, result)
        end
      end

      # Should only process customer 102 (customer 101 was skipped due to error)
      assert_equal 1, metadata_calls.size
      op, args = metadata_calls.first
      assert_equal :update, op
      assert_equal 102, args[:resource_id]
      assert_equal({ "customer_type" => "retail" }, args[:value])
    end

    def test_continues_when_exigo_update_fails
      company = companies(:acme)
      ENV["RAIN_PREFERRED_CUSTOMER_TYPE_ID"] = "2"
      ENV["RAIN_RETAIL_CUSTOMER_TYPE_ID"] = "1"

      metadata_calls = []
      fluid_customers_resource = build_fluid_resource(
        customers: [ { "id" => 101 } ],
        active_autoship_proc: ->(_) { false },
        metadata_calls: metadata_calls
      )

      # Mock ExigoClient where update_customer_type fails
      exigo_client_stub = Class.new do
        def customers_with_active_autoships
          []
        end

        def customer_has_active_autoship?(customer_id)
          false
        end

        def update_customer_type(customer_id, customer_type_id)
          raise ExigoClient::Error, "Update failed"
        end
      end.new

      service = PreferredCustomerSyncService.new(company: company)

      service.stub(:exigo_client, exigo_client_stub) do
        service.stub(:fluid_client, build_fluid_client(fluid_customers_resource, metadata_calls: metadata_calls)) do
          result = service.call
          # Should still succeed even though Exigo update failed
          assert_equal(true, result)
        end
      end

      # Fluid update should still happen
      assert_equal 1, metadata_calls.size
      op, args = metadata_calls.first
      assert_equal :update, op
      assert_equal 101, args[:resource_id]
      assert_equal({ "customer_type" => "retail" }, args[:value])
    end

    def test_skips_customer_when_fluid_preferred_update_fails
      company = companies(:acme)
      ENV["RAIN_PREFERRED_CUSTOMER_TYPE_ID"] = "2"
      ENV["RAIN_RETAIL_CUSTOMER_TYPE_ID"] = "1"

      metadata_calls = []
      fluid_customers_resource = build_fluid_resource(
        customers: [ { "id" => 101 } ],
        active_autoship_proc: ->(_) { false },
        metadata_calls: metadata_calls
      )

      exigo_client_stub = build_exigo_client(
        active_autoship_ids: [ 101 ],  # Customer 101 has Exigo autoship
        has_autoship_proc: ->(_) { true },
        update_customer_type_proc: ->(_id, _type_id) { }
      )

      service = PreferredCustomerSyncService.new(company: company)

      service.stub(:exigo_client, exigo_client_stub) do
        service.stub(:fluid_client,
          build_fluid_client(
            fluid_customers_resource,
            metadata_calls: metadata_calls,
            metafields_update_proc: ->(args) {
              raise FluidClient::Error, "API Error" if args[:value]["customer_type"] == "preferred_customer"
              metadata_calls << [ :update, args ]
            }
          )
        ) do
          result = service.call
          # Should still succeed overall even though one customer failed
          assert_equal(true, result)
        end
      end
    end

    def test_skips_customer_when_fluid_retail_update_fails
      company = companies(:acme)
      ENV["RAIN_PREFERRED_CUSTOMER_TYPE_ID"] = "2"
      ENV["RAIN_RETAIL_CUSTOMER_TYPE_ID"] = "1"

    metadata_calls = []
    fluid_customers_resource = build_fluid_resource(
      customers: [ { "id" => 101 } ],
      active_autoship_proc: ->(_) { false },
      metadata_calls: metadata_calls
    )

      exigo_client_stub = build_exigo_client(
        active_autoship_ids: [],  # No Exigo autoships
        has_autoship_proc: ->(_) { false },
        update_customer_type_proc: ->(_id, _type_id) { }
      )

      service = PreferredCustomerSyncService.new(company: company)

      service.stub(:exigo_client, exigo_client_stub) do
      service.stub(:fluid_client,
        build_fluid_client(
          fluid_customers_resource,
          metadata_calls: metadata_calls,
          metafields_update_proc: ->(args) {
            raise FluidClient::Error, "API Error" if args[:value]["customer_type"] == "retail"
            metadata_calls << [ :update, args ]
          }
        )
      ) do
          result = service.call
          # Should still succeed overall even though one customer failed
          assert_equal(true, result)
        end
      end
    end

    def test_skips_customer_when_fluid_autoship_check_fails
      company = companies(:acme)
      ENV["RAIN_PREFERRED_CUSTOMER_TYPE_ID"] = "2"
      ENV["RAIN_RETAIL_CUSTOMER_TYPE_ID"] = "1"

    metadata_calls = []
    # Mock Fluid client where active_autoship? fails
    fluid_customers_resource = build_fluid_resource(
      customers: [ { "id" => 101 } ],
      active_autoship_proc: ->(_customer_id) { raise FluidClient::Error, "API timeout" },
      metadata_calls: metadata_calls
    )

      exigo_client_stub = build_exigo_client(
        active_autoship_ids: [],  # No Exigo autoships
        has_autoship_proc: ->(_) { false },
        update_customer_type_proc: ->(_id, _type_id) { }
      )

      service = PreferredCustomerSyncService.new(company: company)

      service.stub(:exigo_client, exigo_client_stub) do
      service.stub(:fluid_client, build_fluid_client(fluid_customers_resource, metadata_calls: metadata_calls)) do
          result = service.call
          # Should still succeed overall even though customer was skipped
          assert_equal(true, result)
        end
      end
    end

  private

    def build_exigo_client(active_autoship_ids:, has_autoship_proc:, update_customer_type_proc:)
      Class.new do
        define_method(:customers_with_active_autoships) { active_autoship_ids }
        define_method(:customer_has_active_autoship?, &has_autoship_proc)
        define_method(:update_customer_type, &update_customer_type_proc)
      end.new
    end

  def build_fluid_resource(customers:, active_autoship_proc:, metadata_calls:)
      Class.new do
        define_method(:get) { |_params = nil| { "customers" => customers } }
        define_method(:active_autoship?, &active_autoship_proc)
      # append_metadata no longer used; metafields.update/create capture calls
      define_method(:append_metadata) { |_id, _payload| }
      end.new
    end

  def build_fluid_client(resource, metadata_calls:, metafields_update_proc: nil, metafields_create_proc: nil)
      Class.new do
        define_method(:customers) { resource }
      define_method(:metafields) do
        calls = metadata_calls
        update_proc = metafields_update_proc
        create_proc = metafields_create_proc
        Class.new do
          define_method(:ensure_definition) { |_args = nil| true }
          define_method(:update) do |**args|
            update_proc ? update_proc.call(args) : calls << [ :update, args ]
          end
          define_method(:create) do |**args|
            create_proc ? create_proc.call(args) : calls << [ :create, args ]
          end
        end.new
      end
      end.new
    end
  end
end
