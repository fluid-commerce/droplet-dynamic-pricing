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

      def append_metadata(customer_id, metadata)
        payload = { "metadata" => metadata }
        @client.patch("/api/customers/#{customer_id}/append_metadata", body: payload)
      end
    end
  end
end
