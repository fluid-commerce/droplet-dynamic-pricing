module Fluid
  module Carts
    def carts
      @carts ||= Resource.new(self)
    end

    class Resource
      def initialize(client)
        @client = client
      end

      def update_metadata(cart_token, metadata)
        payload = { "cart" => { "metadata" => metadata } }
        @client.patch("/api/carts/#{cart_token}", body: payload)
      end
    end
  end
end
