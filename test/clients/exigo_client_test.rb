require "test_helper"

class ExigoClientTest < ActiveSupport::TestCase
  class FakeResult
    def initialize(rows)
      @rows = rows
    end

    def to_a
      @rows
    end
  end

  class FakeConnection
    def initialize(rows)
      @rows = rows
    end

    def execute(_query)
      FakeResult.new(@rows)
    end

    def close; end
  end

  def setup
    ENV["TEST_EXIGO_DB_HOST"] = "test_host"
    ENV["TEST_EXIGO_DB_USERNAME"] = "test_user"
    ENV["TEST_EXIGO_DB_PASSWORD"] = "test_pass"
    ENV["TEST_EXIGO_DB_NAME"] = "test_db"
  end

  def teardown
    ENV.delete("TEST_EXIGO_DB_HOST")
    ENV.delete("TEST_EXIGO_DB_USERNAME")
    ENV.delete("TEST_EXIGO_DB_PASSWORD")
    ENV.delete("TEST_EXIGO_DB_NAME")
  end

  test "customer_types returns raw rows" do
    rows = [ { "CustomerTypeID" => 1 }, { "CustomerTypeID" => 2 } ]
    client = ExigoClient.new("TEST")
    client.stub(:establish_connection, FakeConnection.new(rows)) do
      assert_equal rows, client.customer_types
    end
  end

  test "customers_with_active_autoships returns unique ids" do
    rows = [ { "CustomerID" => 10 }, { "CustomerID" => 10 }, { "CustomerID" => 11 } ]
    client = ExigoClient.new("TEST")
    client.stub(:establish_connection, FakeConnection.new(rows)) do
      assert_equal [ 10, 11 ], client.customers_with_active_autoships
    end
  end

  test "customer_has_active_autoship? returns boolean based on count" do
    client = ExigoClient.new("TEST")

    with_autoship = FakeConnection.new([ { "count" => 1 } ])
    without_autoship = FakeConnection.new([ { "count" => 0 } ])

    assert client.stub(:establish_connection, with_autoship) { client.customer_has_active_autoship?(123) }
    refute client.stub(:establish_connection, without_autoship) { client.customer_has_active_autoship?(123) }
  end

  test "execute_non_query consumes result to_a" do
    client = ExigoClient.new("TEST")

    fake_connection = Minitest::Mock.new
    fake_result = Minitest::Mock.new
    fake_result.expect(:to_a, [])
    fake_connection.expect(:execute, fake_result, [String])
    fake_connection.expect(:close, nil)

    client.stub(:establish_connection, fake_connection) do
      client.send(:execute_non_query, "UPDATE dbo.Customers SET CustomerTypeID = 1 WHERE CustomerID = 2")
    end

    fake_result.verify
    fake_connection.verify
    assert fake_result.respond_to?(:to_a)
  end

  test "for_company creates client with company-based credentials" do
    ENV["ACME_EXIGO_DB_HOST"] = "acme.host.com"
    ENV["ACME_EXIGO_DB_USERNAME"] = "acme_user"
    ENV["ACME_EXIGO_DB_PASSWORD"] = "acme_pass"
    ENV["ACME_EXIGO_DB_NAME"] = "acme_db"

    client = ExigoClient.for_company("ACME")

    expected_credentials = {
      "exigo_db_host" => "acme.host.com",
      "exigo_db_username" => "acme_user",
      "exigo_db_password" => "acme_pass",
      "exigo_db_name" => "acme_db",
    }

    assert_equal expected_credentials, client.instance_variable_get(:@credentials)
  end

  test "for_company raises error when company_name is blank" do
    assert_raises(ArgumentError) { ExigoClient.for_company(nil) }
    assert_raises(ArgumentError) { ExigoClient.for_company("") }
  end

  test "initialize raises error when company_name is blank" do
    assert_raises(ArgumentError) { ExigoClient.new(nil) }
    assert_raises(ArgumentError) { ExigoClient.new("") }
  end

  test "for_company handles missing environment variables gracefully" do
    # Clear any existing ENV vars for TEST company
    ENV.delete("TEST_EXIGO_DB_HOST")
    ENV.delete("TEST_EXIGO_DB_USERNAME")
    ENV.delete("TEST_EXIGO_DB_PASSWORD")
    ENV.delete("TEST_EXIGO_DB_NAME")

    client = ExigoClient.for_company("TEST")

    assert_equal({}, client.instance_variable_get(:@credentials))
  end

  test "quote_value safely escapes SQL injection attempts" do
    client = ExigoClient.new("TEST")

    # Test normal string
    assert_equal "N'test'", client.send(:quote_value, "test")

    # Test SQL injection attempt - single quotes should be doubled
    malicious_input = "'; DROP TABLE users; --"
    expected = "N'''; DROP TABLE users; --'"
    assert_equal expected, client.send(:quote_value, malicious_input)

    # Test numbers
    assert_equal "123", client.send(:quote_value, 123)
    assert_equal "123.45", client.send(:quote_value, 123.45)

    # Test boolean and nil
    assert_equal "1", client.send(:quote_value, true)
    assert_equal "0", client.send(:quote_value, false)
    assert_equal "NULL", client.send(:quote_value, nil)
  end
end
