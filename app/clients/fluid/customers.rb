module Fluid
  module Customers
    def customers
      @customers ||= Resource.new(self)
    end

    class Resource
      def initialize(client)
        @client = client
      end

      def get
        @client.get("/api/customers")
      end
    end
  end
end
