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
    ENV["TEST_EXIGO_API_BASE_URL"] = "https://test-api.exigo.com/3.0/"
    ENV["TEST_EXIGO_API_USER"] = "api_test_user"
    ENV["TEST_EXIGO_API_PASSWORD"] = "api_test_pass"
  end

  def teardown
    ENV.delete("TEST_EXIGO_DB_HOST")
    ENV.delete("TEST_EXIGO_DB_USERNAME")
    ENV.delete("TEST_EXIGO_DB_PASSWORD")
    ENV.delete("TEST_EXIGO_DB_NAME")
    ENV.delete("TEST_EXIGO_API_BASE_URL")
    ENV.delete("TEST_EXIGO_API_USER")
    ENV.delete("TEST_EXIGO_API_PASSWORD")
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

  test "update_customer_type uses API REST successfully" do
    client = ExigoClient.new("TEST")

    # Mock successful HTTP response
    mock_response = Minitest::Mock.new
    mock_response.expect(:code, "200")
    mock_response.expect(:body, "{}")
    mock_response.expect(:body, "{}")

    mock_http = Minitest::Mock.new
    mock_http.expect(:use_ssl=, nil, [ true ])
    mock_http.expect(:read_timeout=, nil, [ 30 ])
    mock_http.expect(:open_timeout=, nil, [ 10 ])
    mock_http.expect(:request, mock_response, [ Net::HTTP::Patch ])

    Net::HTTP.stub(:new, ->(*_args) { mock_http }) do
      result = client.update_customer_type(123, 2)
      assert_equal({}, result)
    end

    mock_http.verify
    mock_response.verify
  end

  test "update_customer_type raises ApiError when credentials missing" do
    ENV.delete("TEST_EXIGO_API_BASE_URL")

    client = ExigoClient.new("TEST")

    error = assert_raises(ExigoClient::ApiError) do
      client.update_customer_type(123, 2)
    end

    assert_match(/API credentials not configured/, error.message)
  end

  test "update_customer_type raises ApiError on 401 authentication failure" do
    client = ExigoClient.new("TEST")

    mock_response = Minitest::Mock.new
    mock_response.expect(:code, "401")

    mock_http = Minitest::Mock.new
    mock_http.expect(:use_ssl=, nil, [ true ])
    mock_http.expect(:read_timeout=, nil, [ 30 ])
    mock_http.expect(:open_timeout=, nil, [ 10 ])
    mock_http.expect(:request, mock_response, [ Net::HTTP::Patch ])

    Net::HTTP.stub(:new, ->(*_args) { mock_http }) do
      error = assert_raises(ExigoClient::ApiError) do
        client.update_customer_type(123, 2)
      end

      assert_match(/authentication failed/, error.message)
    end

    mock_http.verify
    mock_response.verify
  end

  test "update_customer_type raises ApiError on 404 customer not found" do
    client = ExigoClient.new("TEST")

    mock_response = Minitest::Mock.new
    mock_response.expect(:code, "404")

    mock_http = Minitest::Mock.new
    mock_http.expect(:use_ssl=, nil, [ true ])
    mock_http.expect(:read_timeout=, nil, [ 30 ])
    mock_http.expect(:open_timeout=, nil, [ 10 ])
    mock_http.expect(:request, mock_response, [ Net::HTTP::Patch ])

    Net::HTTP.stub(:new, ->(*_args) { mock_http }) do
      error = assert_raises(ExigoClient::ApiError) do
        client.update_customer_type(123, 2)
      end

      assert_match(/customer not found/, error.message)
    end

    mock_http.verify
    mock_response.verify
  end

  test "update_customer_type raises ApiError on timeout" do
    client = ExigoClient.new("TEST")

    mock_http = Minitest::Mock.new
    mock_http.expect(:use_ssl=, nil, [ true ])
    mock_http.expect(:read_timeout=, nil, [ 30 ])
    mock_http.expect(:open_timeout=, nil, [ 10 ])

    def mock_http.request(_req)
      raise Net::ReadTimeout, "timeout"
    end

    Net::HTTP.stub(:new, ->(*_args) { mock_http }) do
      error = assert_raises(ExigoClient::ApiError) do
        client.update_customer_type(123, 2)
      end

      assert_match(/timeout/, error.message)
    end

    mock_http.verify
  end

  test "update_customer_type sends correct payload with camelCase" do
    client = ExigoClient.new("TEST")
    customer_id = 6834670
    customer_type_id = 2

    captured_request = nil

    mock_response = Minitest::Mock.new
    mock_response.expect(:code, "200")
    mock_response.expect(:body, "{}")
    mock_response.expect(:body, "{}")

    mock_http = Minitest::Mock.new
    mock_http.expect(:use_ssl=, nil, [ true ])
    mock_http.expect(:read_timeout=, nil, [ 30 ])
    mock_http.expect(:open_timeout=, nil, [ 10 ])
    mock_http.expect(:request, mock_response) do |req|
      captured_request = req
      true
    end

    Net::HTTP.stub(:new, ->(*_args) { mock_http }) do
      client.update_customer_type(customer_id, customer_type_id)
    end

    refute_nil captured_request
    assert_instance_of Net::HTTP::Patch, captured_request

    parsed_body = JSON.parse(captured_request.body)
    assert_equal customer_id, parsed_body["customerID"]
    assert_equal customer_type_id, parsed_body["customerType"]

    mock_http.verify
    mock_response.verify
  end

  test "api_credentials loads from environment variables" do
    client = ExigoClient.new("TEST")

    expected_api_credentials = {
      "api_password" => "api_test_pass",
      "api_username" => "api_test_user",
      "api_base_url" => "https://test-api.exigo.com/3.0/",
      "verify_ssl" => true,
    }

    assert_equal expected_api_credentials, client.instance_variable_get(:@api_credentials)
  end
end
