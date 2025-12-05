module Fluid
  module Companies
    def companies
      @companies ||= Resource.new(self)
    end

    class Resource
      def initialize(client)
        @client = client
      end

      def get
        @client.get("/api/company")
      end
    end
  end
end
