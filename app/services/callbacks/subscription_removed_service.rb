class Callbacks::SubscriptionRemovedService < Callbacks::BaseService
  def call
    cart = @callback_params[:cart]
    return { success: true } if cart.blank?

    cart_token, cart_items = extract_cart_token_and_items(cart)

    update_cart_metadata(cart_token, { "price_type" => nil })

    if cart_items.any?
      cart_items.each do |item|
        item_data = [ {
          "id" => item["id"],
          "price" => item.dig("product", "price") || item["price"],
        } ]
        Rails.logger.info "Updating item #{item['id']} to regular price: #{item_data.first['price']}"
        update_cart_items_prices(cart_token, item_data)
      end

      update_cart_totals(cart_token, cart_items, use_subscription_prices: false)
    end

    { success: true }
  end
end
