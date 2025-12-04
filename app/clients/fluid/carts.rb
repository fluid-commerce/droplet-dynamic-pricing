module Fluid
  module Carts
    def carts
      @carts ||= Resource.new(self)
    end

    class Resource
      def initialize(client)
        @client = client
      end

      def get(cart_token)
        @client.get("/api/carts/#{cart_token}")
      end

      def append_metadata(cart_token, metadata)
        payload = { "cart" => { "metadata" => metadata } }
        @client.patch("/api/carts/#{cart_token}/append_metadata", body: payload)
      end

      def update_items_prices(cart_token, items_data)
        payload = { "cart_items" => items_data }
        @client.patch("/api/carts/#{cart_token}/update_cart_items_prices", body: payload)
      end
    end
  end
end
