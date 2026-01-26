# frozen_string_literal: true

require "tiny_tds"
require "net/http"
require "json"

class ExigoClient
  Error = Class.new(StandardError)
  ConnectionError = Class.new(Error)
  ApiError = Class.new(Error)

  def initialize(company)
    raise ArgumentError, "company must be a Company instance" unless company.is_a?(Company)
    @company = company
    @integration = company.integration_setting

    raise ArgumentError, "Exigo integration not configured for #{company.name}" unless @integration&.exigo_enabled?

    @credentials = @integration.exigo_credentials
  end

  def self.for_company(company)
    new(company)
  end

  def customer_types
    query = <<-SQL.squish
      SELECT * FROM dbo.CustomerTypes
    SQL

    execute_query(query)
  end

  def customers_by_type_id(customer_type_id)
    query = <<-SQL.squish
      SELECT CustomerID FROM dbo.Customers WHERE CustomerTypeID = ?
    SQL

    execute_query(query, [ customer_type_id ]).map { |row| row["CustomerID"] }
  end

  def customers_with_active_autoships
    query = <<-SQL.squish
      SELECT * FROM dbo.AutoOrders
      WHERE AutoOrderStatusID = 0
      AND NextRunDate >= GETDATE()
    SQL

    execute_query(query).map { |row| row["CustomerID"] }.uniq
  end

  def customer_has_active_autoship?(customer_id)
    query = <<-SQL.squish
      SELECT COUNT(*) AS count FROM dbo.AutoOrders
      WHERE CustomerID = ?
      AND AutoOrderStatusID = 0
      AND NextRunDate >= GETDATE()
    SQL

    result = execute_query(query, [ customer_id.to_i ])
    result.first&.dig("count").to_i > 0
  end

  def customer_has_active_autoship_by_email?(email)
    query = <<-SQL.squish
      SELECT COUNT(*) AS count
      FROM dbo.AutoOrders ao
      INNER JOIN dbo.Customers c ON ao.CustomerID = c.CustomerID
      WHERE c.Email = ?
      AND ao.AutoOrderStatusID = 0
      AND ao.NextRunDate >= GETDATE()
    SQL

    result = execute_query(query, [ email.to_s ])
    result.first&.dig("count").to_i > 0
  end

  def find_customer_id_by_email(email)
    query = <<-SQL.squish
      SELECT CustomerID FROM dbo.Customers WHERE Email = ?
    SQL

    result = execute_query(query, [ email.to_s ])
    result.first&.dig("CustomerID")
  end

  def get_customer_type(customer_id)
    query = <<-SQL.squish
      SELECT CustomerTypeID FROM dbo.Customers WHERE CustomerID = ?
    SQL

    result = execute_query(query, [ customer_id.to_i ])
    result.first&.dig("CustomerTypeID")
  end

  def update_customer_type(customer_id, customer_type_id)
    update_customer_via_api(customer_id, customer_type_id)
  end

private

  attr_reader :company, :integration, :credentials

  def execute_query(query, params = [])
    connection = establish_connection

    if params.any?
      parameterized_query = query.dup
      params.each_with_index do |_, index|
        parameterized_query = parameterized_query.sub("?", "@param#{index}")
      end

      declare_statements = params.each_with_index.map do |param, index|
        sql_type = case param
        when Integer
          "INT"
        when Float
          "FLOAT"
        else
          "NVARCHAR(MAX)"
        end
        "DECLARE @param#{index} #{sql_type} = #{quote_value(param)}"
      end

      full_query = declare_statements.join("; ") + "; " + parameterized_query
      result = connection.execute(full_query)
    else
      result = connection.execute(query)
    end

    result.to_a
  ensure
    connection&.close
  end

  def establish_connection
    TinyTds::Client.new(
      host: credentials[:db_host],
      username: credentials[:db_username],
      password: credentials[:db_password],
      database: credentials[:db_name],
      azure: true,
      login_timeout: 5,
      timeout: 15,
    )
  rescue StandardError => e
    raise ConnectionError, "Failed to connect to Exigo SQL Server database: #{e.message}"
  end


  def update_customer_via_api(customer_id, customer_type_id)
    base_url, username, password = extract_api_credentials

    uri = URI.join(base_url, "customers")
    http = configure_http_client(uri)

    request = Net::HTTP::Patch.new(uri.path, "Content-Type" => "application/json")
    request.basic_auth(username, password)

    payload = {
      "customerID" => customer_id.to_i,
      "customerType" => customer_type_id.to_i,
    }

    request.body = payload.to_json

    response = http.request(request)

    case response.code.to_i
    when 200..299
      JSON.parse(response.body) if response.body.present?
    when 401
      raise ApiError, "Exigo API authentication failed"
    when 404
      raise ApiError, "Exigo customer not found: #{customer_id}"
    else
      raise ApiError, "Exigo API error (#{response.code}): #{response.body}"
    end
  rescue JSON::ParserError => e
    raise ApiError, "Invalid JSON response from Exigo API: #{e.message}"
  rescue Net::OpenTimeout, Net::ReadTimeout => e
    raise ApiError, "Exigo API timeout: #{e.message}"
  rescue StandardError => e
    raise ApiError, "Exigo API request failed: #{e.message}"
  end

  def extract_api_credentials
    base_url = credentials[:api_base_url]
    username = credentials[:api_username]
    password = credentials[:api_password]

    unless base_url.present? && username.present? && password.present?
      raise ApiError, "Exigo API credentials not configured for #{company.name}"
    end

    [ base_url, username, password ]
  end

  def configure_http_client(uri)
    http = Net::HTTP.new(uri.host, uri.port)
    http.read_timeout = 30
    http.open_timeout = 10

    if uri.scheme == "https"
      http.use_ssl = true
    end

    http
  end

  def quote_value(value)
    case value
    when Integer, Float
      value.to_s
    when String
      escaped_value = value.gsub("'", "''")
      "N'#{escaped_value}'"
    when NilClass
      "NULL"
    when TrueClass
      "1"
    when FalseClass
      "0"
    else
      escaped_value = value.to_s.gsub("'", "''")
      "N'#{escaped_value}'"
    end
  end
end
