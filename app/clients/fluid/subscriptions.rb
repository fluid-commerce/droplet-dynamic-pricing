module Fluid
  module Subscriptions
    def subscriptions
      @subscriptions ||= Resource.new(self)
    end

    class Resource
      def initialize(client)
        @client = client
      end

      def get_by_customer(customer_id, params = {})
        query_params = params.merge(customer_id: customer_id)
        query = build_query_string(query_params)
        @client.get("/api/subscriptions#{query}")
      end

    private

      def build_query_string(params)
        return "" if params.empty?

        query_params = []
        query_params << "page=#{params[:page]}" if params.key?(:page)
        query_params << "per_page=#{params[:per_page]}" if params.key?(:per_page)
        query_params << "status=#{params[:status]}" if params.key?(:status)
        query_params << "status=#{params[:status]}" if params.key?(:status)
        query_params << "customer_id=#{params[:customer_id]}" if params.key?(:customer_id)
        "?#{query_params.join('&')}"
      end
    end
  end
end
