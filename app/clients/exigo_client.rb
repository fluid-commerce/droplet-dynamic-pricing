# frozen_string_literal: true

require "tiny_tds"

class ExigoClient
  Error = Class.new(StandardError)
  ConnectionError = Class.new(Error)

  def initialize(connection_config)
    @connection_config = connection_config
  end
  def customers_by_type_id(customer_type_id)
    query = <<-SQL.squish
      SELECT CustomerID
      FROM dbo.Customers
      WHERE CustomerTypeID = ?
    SQL

    execute_query(query, [ customer_type_id ]).map { |row| row["CustomerID"] }
  end

  def customers_with_active_autoships
    query = <<-SQL.squish
      SELECT DISTINCT CustomerID
      FROM dbo.AutoOrders
      WHERE AutoOrderStatusID = 0
      AND NextRunDate >= GETUTCDATE()
    SQL

    execute_query(query).map { |row| row["CustomerID"] }
  end

  def establish_connection
    TinyTds::Client.new(@connection_config)
  rescue StandardError => e
    raise ConnectionError, "Failed to connect to Exigo SQL Server database: #{e.message}"
  end

  def execute_query(query, params = [])
    connection = establish_connection
    result = connection.execute(query, params)
    rows = result.map { |row| row }
    rows
  ensure
    connection&.close
  end

  def connection_config
    @connection_config ||= {
      host: ENV.fetch("RAIN_EXIGO_DB_HOST", nil),
      username: ENV.fetch("RAIN_DB_EXIGO_USERNAME", nil),
      password: ENV.fetch("RAIN_EXIGO_DB_PASSWORD", nil),
      name: ENV.fetch("RAIN_EXIGO_DB_NAME", nil),
    }
  end
end
