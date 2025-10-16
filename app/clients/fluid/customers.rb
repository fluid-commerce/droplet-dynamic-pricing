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

      def append_metadata(customer_id, metadata)
        payload = { "metadata" => metadata }
        @client.patch("/api/customers/#{customer_id}/append_metadata", body: payload)
      end

    private

      def build_query_string(params)
        return "" if params.empty?

        query_params = []
        query_params << "page=#{params[:page]}" if params.key?(:page)
        query_params << "per_page=#{params[:per_page]}" if params.key?(:per_page)

        "?#{query_params.join('&')}"
      end
    end
  end
end
