module Fluid
  module Variants
    def variants
      @variants ||= Resource.new(self)
    end

    class Resource
      def initialize(client)
        @client = client
      end

      def get(variant_id)
        @client.get("/api/company/v1/variants/#{variant_id}")
      end
    end
  end
end
