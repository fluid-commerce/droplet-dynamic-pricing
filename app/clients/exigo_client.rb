# frozen_string_literal: true

require "tiny_tds"

class ExigoClient
  Error = Class.new(StandardError)
  ConnectionError = Class.new(Error)

  attr_reader :credentials

  def initialize(company_name)
    raise ArgumentError, "company_name must be present" unless company_name.present?
    @credentials = build_credentials_from_company(company_name)
  end

  def self.for_company(company_name)
    new(company_name)
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

    result = execute_query(query, [ customer_id ])
    result.first["count"].to_i.positive?
  end

  def update_customer_type(customer_id, customer_type_id)
    query = <<-SQL.squish
      UPDATE dbo.Customers
      SET CustomerTypeID = ?
      WHERE CustomerID = ?
    SQL

    execute_non_query(query, [ customer_type_id, customer_id ])
  end

  def establish_connection
    TinyTds::Client.new(
      host: credentials["exigo_db_host"],
      username: credentials["exigo_db_username"],
      password: credentials["exigo_db_password"],
      database: credentials["exigo_db_name"],
      azure: true,
      login_timeout: 5,
      timeout: 15,
    )
  rescue StandardError => e
    raise ConnectionError, "Failed to connect to Exigo SQL Server database: #{e.message}"
  end

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

    rows = result.map { |row| row }
    rows
  ensure
    connection&.close
  end

  def execute_non_query(query, params = [])
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
      connection.execute(full_query)
    else
      connection.execute(query)
    end
  ensure
    connection&.close
  end

private

  def build_credentials_from_company(company_name)
    return {} unless company_name.present?

    company_prefix = company_name.upcase
    {
      "exigo_db_host"      => ENV.fetch("#{company_prefix}_EXIGO_DB_HOST", nil),
      "exigo_db_username"  => ENV.fetch("#{company_prefix}_EXIGO_DB_USERNAME", nil),
      "exigo_db_password"  => ENV.fetch("#{company_prefix}_EXIGO_DB_PASSWORD", nil),
      "exigo_db_name"      => ENV.fetch("#{company_prefix}_EXIGO_DB_NAME", nil),
    }.compact
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
