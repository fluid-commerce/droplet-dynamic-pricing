require "cgi"

module Fluid
  module Customers
    def customers
      @customers ||= Resource.new(self)
    end

    class Resource
      def initialize(client)
        @client = client
      end

      def get(params = {})
        query = build_query_string(params)
        @client.get("/api/customers#{query}")
      end

      def find(customer_id)
        @client.get("/api/customers/#{customer_id}")
      end

      def append_metadata(customer_id, metadata)
        payload = { "metadata" => metadata }
        @client.patch("/api/customers/#{customer_id}/append_metadata", body: payload)
      end

      def active_autoship?(customer_id)
        response = find(customer_id)
        response["has_active_autoship"] || response.dig("customer", "has_active_autoship") || false
      rescue FluidClient::Error => e
        Rails.logger.warn("Failed to check Fluid autoship for customer #{customer_id}: #{e.message}")
        true
      end

    private

      def build_query_string(params)
        return "" if params.empty?

        query_params = []
        query_params << "page=#{params[:page]}" if params.key?(:page)
        query_params << "per_page=#{params[:per_page]}" if params.key?(:per_page)

        if params.key?(:by_metadata)
          raw_metadata = params[:by_metadata]
          json_metadata = raw_metadata.is_a?(String) ? raw_metadata : raw_metadata.to_json
          query_params << "by_metadata=#{CGI.escape(json_metadata)}"
        end

        if params.key?(:country_code)
          country_codes = Array(params[:country_code])
          country_codes.each do |code|
            query_params << "country_code[]=#{CGI.escape(code.to_s)}"
          end
        end

        "?#{query_params.join('&')}"
      end
    end
  end
end
