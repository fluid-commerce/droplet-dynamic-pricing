require "cgi"

module Fluid
  module Metafields
    def metafields
      @metafields ||= Resource.new(self)
    end

    class Resource
      def initialize(client)
        @client = client
      end

      def get(resource_type:, resource_id:, page: 1, per_page: 100)
        query_params = []
        query_params << "resource_type=#{CGI.escape(resource_type.to_s)}"
        query_params << "resource_id=#{resource_id}"
        query_params << "page=#{page}"
        query_params << "per_page=#{per_page}"

        @client.get("/api/v2/metafields?#{query_params.join('&')}")
      end

      def get_by_key(resource_type:, resource_id:, key:, page: 1, per_page: 100)
        response = get(resource_type: resource_type, resource_id: resource_id, page: page, per_page: per_page)
        metafields = response["metafields"] || []

        metafields.find { |metafield| metafield["key"] == key.to_s || metafield[:key] == key.to_sym }
      end
    end
  end
end
