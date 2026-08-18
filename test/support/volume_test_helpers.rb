# Shared fakes for the volume-adjustment service hooks (STU2-2526).
module VolumeTestHelpers
  class FakeVariants
    def initialize(countries_by_variant_id)
      @countries_by_variant_id = countries_by_variant_id
    end

    def get(variant_id)
      { "variant" => { "id" => variant_id, "variant_countries" => (@countries_by_variant_id[variant_id] || []) } }
    end
  end

  class FakeCarts
    attr_reader :items_prices_calls, :metadata_calls, :volume_calls

    def initialize
      @items_prices_calls = []
      @metadata_calls = []
      @volume_calls = []
    end

    def update_items_prices(token, items)
      @items_prices_calls << { token: token, items: items }
      { "success" => true }
    end

    def append_metadata(token, metadata)
      @metadata_calls << { token: token, metadata: metadata }
      { "success" => true }
    end

    def update_item_volumes(token, item_id, volumes)
      @volume_calls << { token: token, item_id: item_id, volumes: volumes }
      { "success" => true }
    end
  end

  # Answers "this customer has no subscriptions" rather than blowing up. Without it
  # has_active_subscriptions? raises NoMethodError, the service swallows it, and the
  # test silently exercises the lookup-failed path instead of the one it names.
  class FakeSubscriptions
    def initialize(subscriptions = []) = @subscriptions = subscriptions
    def get_by_customer(_customer_id, **) = { "subscriptions" => @subscriptions }
  end

  def build_volume_client(carts:, variants:, subscriptions: FakeSubscriptions.new)
    client = Object.new
    client.define_singleton_method(:carts) { carts }
    client.define_singleton_method(:variants) { variants }
    client.define_singleton_method(:subscriptions) { subscriptions }
    client
  end
end
