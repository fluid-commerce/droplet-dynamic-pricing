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

      # Metafield definitions helpers (best effort)
      def find_definition_by_key(owner_resource:, key:, page: 1, per_page: 50)
        query_params = []
        query_params << "owner_resource=#{CGI.escape(owner_resource.to_s)}"
        query_params << "search_query=#{CGI.escape(key.to_s)}"
        query_params << "page=#{page}"
        query_params << "per_page=#{per_page}"

        response = @client.get("/api/v2/metafield_definitions?#{query_params.join('&')}")
        defs = response["metafield_definitions"] || []
        defs.find { |definition| definition["key"] == key.to_s || definition[:key] == key.to_sym }
      end

      def create_definition(namespace:, key:, value_type:, description: nil, owner_resource: "Customer")
        payload = {
          "metafield_definition" => {
            "namespace" => namespace.to_s,
            "key" => key.to_s,
            "name" => key.to_s,
            "value_type" => value_type.to_s,
            "owner_resource" => owner_resource.to_s,
            "description" => description.to_s,
            "pinned" => false,
            "locked" => false,
          }.compact,
        }

        @client.post("/api/v2/metafield_definitions", body: payload)
      end

      def ensure_definition(namespace:, key:, value_type:, description: nil, owner_resource: "Customer")
        existing = find_definition_by_key(owner_resource: owner_resource, key: key)
        return existing if existing

        create_definition(
          namespace: namespace,
          key: key,
          value_type: value_type,
          description: description,
          owner_resource: owner_resource
        )
      rescue FluidClient::Error => e
        msg = e.message.to_s.downcase
        raise unless msg.include?("already") || msg.include?("duplicate")
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

      # Creates a metafield value for the given resource. Use when update returns not found.
      def create(resource_type:, resource_id:, namespace:, key:, value:, value_type:, description: nil)
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

        @client.post("/api/v2/metafields", body: payload)
      end
    end
  end
end
