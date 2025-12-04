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
    TinyTds::Client.new(
      host: @connection_config[:host] || @connection_config["host"],
      database: @connection_config[:database] || @connection_config["database"],
      username: @connection_config[:username] || @connection_config["username"],
      password: @connection_config[:password] || @connection_config["password"],
      port: (@connection_config[:port] || @connection_config["port"] || 1433).to_i,
      timeout: 30
    )
  rescue StandardError => e
    raise ConnectionError, "Failed to connect to Exigo SQL Server database: #{e.message}"
  end
end
