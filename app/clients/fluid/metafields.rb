module Fluid
  module Metafields
    def metafields
      @metafields ||= Resource.new(self)
    end

    class Resource
      def initialize(client)
        @client = client
      end

      def update(resource_type:, resource_id:, namespace:, key:, value:, value_type:, description: nil)
        if value.blank?
          raise ArgumentError, "value cannot be blank"
        end

        formatted_value = value_type.to_s == "json" ? value : value.to_s

        payload = {
          "resource_type" => resource_type.to_s,
          "resource_id" => resource_id.to_i,
          "namespace" => namespace.to_s,
          "key" => key.to_s,
          "value" => formatted_value,
          "value_type" => value_type.to_s,
        }
        payload["description"] = description.to_s if description.present?

        @client.patch("/api/v2/metafields/update", body: payload)
      end
    end
  end
end
