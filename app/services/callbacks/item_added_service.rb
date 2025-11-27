class Callbacks::ItemAddedService < Callbacks::BaseService
  def call
    cart = @callback_params[:cart]
    cart_item = @callback_params[:cart_item]

    return { success: true } if cart.blank? || cart_item.blank?

    price_type = cart.dig("metadata", "price_type")
    return { success: true } unless price_type == "preferred_customer"

    cart_token = cart["cart_token"]

    item_data = [ {
      "id" => cart_item["id"],
      "price" => cart_item["subscription_price"] || cart_item["price"],
    } ]

    Rails.logger.info "Updating newly added item #{cart_item['id']} to subscription price: #{item_data.first['price']}"

    update_cart_items_prices(cart_token, item_data)

    # Update totals with all cart items using subscription prices
    cart_items = cart["items"] || []
    update_cart_totals(cart_token, cart_items, use_subscription_prices: true)

    { success: true }
  end
end
