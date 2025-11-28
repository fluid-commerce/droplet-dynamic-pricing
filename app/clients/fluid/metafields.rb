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
        @client.get("/api/v2/metafields?resource_type=#{resource_type}&resource_id=#{resource_id}&page=#{page}&per_page=#{per_page}")
      end
    end
  end
end
