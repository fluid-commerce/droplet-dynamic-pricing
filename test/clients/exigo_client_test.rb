require "test_helper"

class ExigoClientTest < ActiveSupport::TestCase
  class FakeConnection
    def initialize(rows)
      @rows = rows
    end

    def execute(_query)
      @rows
    end

    def close; end
  end

  test "customer_types returns raw rows" do
    rows = [ { "CustomerTypeID" => 1 }, { "CustomerTypeID" => 2 } ]
    client = ExigoClient.new
    client.stub(:establish_connection, FakeConnection.new(rows)) do
      assert_equal rows, client.customer_types
    end
  end

  test "customers_with_active_autoships returns unique ids" do
    rows = [ { "CustomerID" => 10 }, { "CustomerID" => 10 }, { "CustomerID" => 11 } ]
    client = ExigoClient.new
    client.stub(:establish_connection, FakeConnection.new(rows)) do
      assert_equal [ 10, 11 ], client.customers_with_active_autoships
    end
  end

  test "customer_has_active_autoship? returns boolean based on count" do
    client = ExigoClient.new

    with_autoship = FakeConnection.new([ { "count" => 1 } ])
    without_autoship = FakeConnection.new([ { "count" => 0 } ])

    assert client.stub(:establish_connection, with_autoship) { client.customer_has_active_autoship?(123) }
    refute client.stub(:establish_connection, without_autoship) { client.customer_has_active_autoship?(123) }
  end
end

