require "cgi"

module Fluid
  module Carts
    def carts
      @carts ||= Resource.new(self)
    end

    class Resource
      def initialize(client)
        @client = client
      end

      def get(cart_id)
        @client.get("/api/carts/#{cart_id}")
      end

      def update_metadata(cart_id, metadata)
        payload = { "cart" => { "metadata" => metadata } }
        @client.patch("/api/carts/#{cart_id}", body: payload)
      end

      def update_items_prices(cart_id, items_data)
        payload = {
          "cart_id" => cart_id,
          "items" => items_data,
        }
        @client.patch("/api/carts/#{cart_id}/update_items_prices", body: payload)
      end

      # Alternative method name matching the API documentation
      def updatecartitemsprices(cart_id, items_data)
        update_items_prices(cart_id, items_data)
      end

      # Get cart items with pricing information
      def get_items(cart_id)
        response = get(cart_id)
        response.dig("cart", "items") || []
      end

      # Helper method to build items data for price updates
      def build_items_data_for_subscription_pricing(cart_items)
        cart_items.map do |item|
          {
            "id" => item["id"],
            "price" => item["subscription_price"] || item["price"],
            "subscription" => true,
          }
        end
      end

      # Helper method to build items data for regular pricing
      def build_items_data_for_regular_pricing(cart_items)
        cart_items.map do |item|
          {
            "id" => item["id"],
            "price" => item["price"], # Use original price
            "subscription" => false,
          }
        end
      end
    end
  end
end
