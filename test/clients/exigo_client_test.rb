require "test_helper"

class ExigoClientTest < ActiveSupport::TestCase
  fixtures(:companies)

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

  # Records the SQL it is handed so the DECLARE the client builds is assertable
  # — the point of the customer-type path is which type the parameter binds as.
  class RecordingConnection
    attr_reader :queries

    def initialize(rows)
      @rows = rows
      @queries = []
    end

    def execute(query)
      @queries << query
      FakeResult.new(@rows)
    end

    def close; end
  end

  def setup
    @company = companies(:acme)
    @integration_setting = IntegrationSetting.create!(
      company: @company,
      enabled: true,
      credentials: {
        exigo_db_host: "test_host",
        exigo_db_username: "test_user",
        exigo_db_password: "test_pass",
        exigo_db_name: "test_db",
        api_base_url: "https://test-api.exigo.com/3.0/",
        api_username: "api_test_user",
        api_password: "api_test_pass",
      },
      settings: {}
    )
  end

  test "customer_types returns raw rows" do
    rows = [ { "CustomerTypeID" => 1 }, { "CustomerTypeID" => 2 } ]
    client = ExigoClient.for_company(@company)
    client.stub(:establish_connection, FakeConnection.new(rows)) do
      assert_equal rows, client.customer_types
    end
  end

  test "customers_with_active_autoships returns unique ids" do
    rows = [ { "CustomerID" => 10 }, { "CustomerID" => 10 }, { "CustomerID" => 11 } ]
    client = ExigoClient.for_company(@company)
    client.stub(:establish_connection, FakeConnection.new(rows)) do
      assert_equal [ 10, 11 ], client.customers_with_active_autoships
    end
  end

  test "customers_by_type_id returns the ids of that type" do
    rows = [ { "CustomerID" => 10 }, { "CustomerID" => 11 } ]
    client = ExigoClient.for_company(@company)
    client.stub(:establish_connection, FakeConnection.new(rows)) do
      assert_equal [ 10, 11 ], client.customers_by_type_id(2)
    end
  end

  # preferred_customer_type_id is a String everywhere it comes from (the JSONB
  # default is "2", and the admin form writes a text field), so the id reaching
  # this query is a String in practice. Binding it as NVARCHAR leans on SQL
  # Server's implicit conversion of an int column; bind INT instead.
  test "customers_by_type_id binds a string type id as INT" do
    connection = RecordingConnection.new([])
    client = ExigoClient.for_company(@company)
    client.stub(:establish_connection, connection) do
      client.customers_by_type_id("2")
    end

    assert_includes connection.queries.first, "DECLARE @param0 INT = 2"
  end

  test "customer_type_by_email returns the type id for that email" do
    rows = [ { "CustomerTypeID" => 2 } ]
    client = ExigoClient.for_company(@company)
    client.stub(:establish_connection, FakeConnection.new(rows)) do
      assert_equal 2, client.customer_type_by_email("shopper@example.com")
    end
  end

  test "customer_type_by_email returns nil when no customer has that email" do
    client = ExigoClient.for_company(@company)
    client.stub(:establish_connection, FakeConnection.new([])) do
      assert_nil client.customer_type_by_email("nobody@example.com")
    end
  end

  # The callback path holds only an email, and every execute_query opens and
  # closes its own TinyTds connection. Resolving the id first and then the type
  # would double the connects inside a callback's budget, so this has to stay a
  # single query — the same shape customer_has_active_autoship_by_email? uses.
  test "customer_type_by_email reads the type in one query" do
    connection = RecordingConnection.new([ { "CustomerTypeID" => 2 } ])
    client = ExigoClient.for_company(@company)
    client.stub(:establish_connection, connection) do
      client.customer_type_by_email("shopper@example.com")
    end

    assert_equal 1, connection.queries.size
    assert_includes connection.queries.first, "N'shopper@example.com'"
  end

  # tiny_tds rewrites the login to "user@<first host label>" whenever azure: is
  # set, which only Azure SQL's gateway strips back off. Exigo's own servers
  # took it literally: Yoli's production login reached 1160-drsql.epic-ha.com
  # as 'Yoli_FluidProd@1160-drsql' and was refused (ENG-1955).
  def connection_options_for(host)
    @integration_setting.update!(credentials: @integration_setting.credentials.merge("exigo_db_host" => host))
    captured = nil
    TinyTds::Client.stub(:new, ->(opts) { captured = opts }) do
      ExigoClient.for_company(@company).send(:establish_connection)
    end
    captured
  end

  test "establish_connection sends the username untouched to a non-Azure host" do
    opts = connection_options_for("1160-drsql.epic-ha.com")

    assert_equal "test_user", TinyTds::Client.allocate.send(:parse_username, opts)
    assert_equal "test_db", opts[:database]
  end

  # contained: selects the database at login, as azure: did, so the only
  # thing that changes for a non-Azure host is the login name.
  test "establish_connection still selects the database at login on a non-Azure host" do
    opts = connection_options_for("1160-drsql.epic-ha.com")

    assert_not opts[:azure]
    assert opts[:contained]
  end

  test "establish_connection keeps azure on for an Azure SQL host" do
    opts = connection_options_for("exigo-rain.database.windows.net")

    assert opts[:azure]
    assert_equal "test_user@exigo-rain", TinyTds::Client.allocate.send(:parse_username, opts)
  end

  test "for_company creates client with company-based credentials" do
    globex = companies(:globex)
    globex_integration = IntegrationSetting.create!(
      company: globex,
      enabled: true,
      credentials: {
        exigo_db_host: "acme.host.com",
        exigo_db_username: "acme_user",
        exigo_db_password: "acme_pass",
        exigo_db_name: "acme_db",
        api_base_url: "https://api.example.com",
        api_username: "api_user",
        api_password: "api_pass",
      },
      settings: {}
    )

    client = ExigoClient.for_company(globex)

    expected_credentials = {
      db_host: "acme.host.com",
      db_username: "acme_user",
      db_password: "acme_pass",
      db_name: "acme_db",
      api_base_url: "https://api.example.com",
      api_username: "api_user",
      api_password: "api_pass",
    }

    assert_equal expected_credentials, client.instance_variable_get(:@credentials)
  end

  test "for_company raises error when company is nil" do
    assert_raises(ArgumentError) { ExigoClient.for_company(nil) }
  end

  test "for_company raises error when company is not a Company instance" do
    assert_raises(ArgumentError) { ExigoClient.for_company("not a company") }
  end

  test "initialize raises error when company is nil" do
    assert_raises(ArgumentError) { ExigoClient.new(nil) }
  end

  test "initialize raises error when company is not a Company instance" do
    assert_raises(ArgumentError) { ExigoClient.new("not a company") }
  end


  test "quote_value safely escapes SQL injection attempts" do
    client = ExigoClient.for_company(@company)

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
    client = ExigoClient.for_company(@company)

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
    company_no_api = companies(:globex)
    IntegrationSetting.create!(
      company: company_no_api,
      enabled: true,
      credentials: {
        exigo_db_host: "db.example.com",
        exigo_db_username: "user",
        exigo_db_password: "pass",
        exigo_db_name: "exigo_db",
        api_base_url: "https://api.example.com",
        api_username: "api_user",
        api_password: "api_pass",
      },
      settings: {}
    )

    client = ExigoClient.for_company(company_no_api)

    # Stub credentials to remove API credentials after client creation
    client.stub(:credentials, {
      db_host: "db.example.com",
      db_username: "user",
      db_password: "pass",
      db_name: "exigo_db",
      # API credentials missing
    }) do
      error = assert_raises(ExigoClient::ApiError) do
        client.update_customer_type(123, 2)
      end

      assert_match(/API credentials not configured/, error.message)
    end
  end

  test "update_customer_type raises ApiError on 401 authentication failure" do
    client = ExigoClient.for_company(@company)

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
    client = ExigoClient.for_company(@company)

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
    client = ExigoClient.for_company(@company)

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
    client = ExigoClient.for_company(@company)
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

  test "credentials loads from integration_setting" do
    client = ExigoClient.for_company(@company)

    expected_credentials = {
      db_host: "test_host",
      db_username: "test_user",
      db_password: "test_pass",
      db_name: "test_db",
      api_base_url: "https://test-api.exigo.com/3.0/",
      api_username: "api_test_user",
      api_password: "api_test_pass",
    }

    assert_equal expected_credentials, client.instance_variable_get(:@credentials)
  end

  class FakeHttp
    attr_reader :requests

    def initialize(code, body = "")
      @response = Struct.new(:code, :body).new(code, body)
      @requests = []
    end

    def request(req)
      @requests << req
      @response
    end
  end

  def check_api_with(http)
    client = ExigoClient.for_company(@company)
    client.stub(:configure_http_client, http) { client.check_api }
  end

  test "check_database passes when a trivial query runs" do
    connection = RecordingConnection.new([ { "ok" => 1 } ])
    client = ExigoClient.for_company(@company)
    result = client.stub(:establish_connection, connection) { client.check_database }

    assert result[:ok]
    assert_equal [ "SELECT 1 AS ok" ], connection.queries
  end

  test "check_database does not try to connect without a host" do
    client = ExigoClient.for_company(@company)
    result = client.stub(:credentials, {}) do
      client.stub(:establish_connection, -> { flunk "should not connect" }) { client.check_database }
    end

    assert_not result[:ok]
    assert_match(/not configured/, result[:message])
  end

  test "check_database reports the server's login error" do
    client = ExigoClient.for_company(@company)
    failing = -> { raise ExigoClient::ConnectionError, "Login failed for user 'test_user'." }
    result = client.stub(:establish_connection, failing) { client.check_database }

    assert_not result[:ok]
    assert_match(/Login failed for user 'test_user'/, result[:message])
  end

  test "check_api only ever issues a GET" do
    http = FakeHttp.new("200", "[]")
    check_api_with(http)

    assert_equal [ Net::HTTP::Get ], http.requests.map(&:class)
    encoded = http.requests.first["authorization"].split.last
    assert_equal "api_test_user", Base64.decode64(encoded).split(":").first
  end

  test "check_api passes when Exigo accepts the credentials" do
    assert check_api_with(FakeHttp.new("200", "[]"))[:ok]
  end

  # The probe asks for a customer that does not exist, so a 404 still proves
  # the credentials got past authentication.
  test "check_api passes on a 404, which is past authentication" do
    result = check_api_with(FakeHttp.new("404", "not found"))

    assert result[:ok]
    assert_match(/404/, result[:message])
  end

  test "check_api fails when Exigo rejects the credentials" do
    %w[401 403].each do |code|
      result = check_api_with(FakeHttp.new(code, "denied"))

      assert_not result[:ok], "expected #{code} to fail"
      assert_match(/rejected/, result[:message])
    end
  end

  test "check_api fails on a server error" do
    assert_not check_api_with(FakeHttp.new("500", "boom"))[:ok]
  end

  test "check_api fails without raising when the host is unreachable" do
    unreachable = Object.new
    def unreachable.request(_req) = raise(Net::OpenTimeout, "execution expired")
    result = check_api_with(unreachable)

    assert_not result[:ok]
    assert_match(/execution expired/, result[:message])
  end

  test "neither check echoes a password" do
    client = ExigoClient.for_company(@company)
    failing = -> { raise ExigoClient::ConnectionError, "boom" }
    db = client.stub(:establish_connection, failing) { client.check_database }
    api = check_api_with(FakeHttp.new("401", "denied"))

    [ db, api ].each do |result|
      assert_no_match(/test_pass|api_test_pass/, result.to_s)
    end
  end
end
