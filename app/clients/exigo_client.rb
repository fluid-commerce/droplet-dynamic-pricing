# frozen_string_literal: true

require "tiny_tds"

class ExigoClient
  Error = Class.new(StandardError)
  ConnectionError = Class.new(Error)

  attr_reader :credentials

  def initialize(credentials = {})
    @credentials = credentials
  end

  def customer_types
    query = <<-SQL.squish
      SELECT * FROM Dbo.CustomerTypes
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

  def establish_connection
    TinyTds::Client.new(@connection_config)
  rescue StandardError => e
    raise ConnectionError, "Failed to connect to Exigo SQL Server database: #{e.message}"
  end

  def execute_query(query, params = [])
    connection = establish_connection

    if params.any?
      params.each_with_index do |param, index|
        safe_value = case param
        when Numeric
          param
        when String
          "'#{param.gsub("'", "''")}'"
        else
          param.to_s.gsub("'", "''")
        end
        query = query.sub("?", safe_value.to_s)
      end
    end

    result = connection.execute(query)
    rows = result.map { |row| row }
    rows
  ensure
    connection&.close
  end

  def connection_config
    {
      host: credentials["exigo_db_host"],
      username: credentials["db_exigo_username"],
      password: credentials["exigo_db_password"],
      name: credentials["exigo_db_name"],
    }
  end
end
