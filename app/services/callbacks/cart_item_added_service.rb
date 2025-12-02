class Callbacks::CartItemAddedService < Callbacks::BaseService
  def call
    params = normalize_params
    cart, cart_item = extract_cart_and_item(params)

    return log_and_return("Cart or cart_item data is missing", success: false) if cart.blank? || cart_item.blank?

    price_type = cart.dig("metadata", "price_type")
    return log_and_return("Cart does not have preferred_customer pricing") unless price_type == PREFERRED_CUSTOMER_TYPE

    cart_token = cart["cart_token"]
    return log_and_return("Cart token is missing", success: false) if cart_token.blank?

    update_result = update_item_to_subscription_price(cart_token, cart_item)
    return update_result if update_result[:success] == false

    update_totals_result = update_cart_totals_with_subscription_prices(cart_token, cart)
    return update_totals_result if update_totals_result[:success] == false

    log_and_return("Cart item updated to subscription price successfully", success: true)
  end

private

  def normalize_params
    @callback_params.with_indifferent_access
  end

  def extract_cart_and_item(params)
    cart = params["cart"]
    cart_item = params["cart_item"]
    [ cart, cart_item ]
  end

  def update_item_to_subscription_price(cart_token, cart_item)
    item_data = [ {
      "id" => cart_item["id"],
      "price" => cart_item["subscription_price"] || cart_item["price"],
    } ]

    Rails.logger.info "Updating newly added item #{cart_item['id']} to subscription price: #{item_data.first['price']}"

    update_cart_items_prices(cart_token, item_data)
    { success: true }
  rescue StandardError => e
    Rails.logger.error "Failed to update item prices for cart #{cart_token}: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    { success: false, error: "item_price_update_failed", message: "Unable to update item prices" }
  end

  def update_cart_totals_with_subscription_prices(cart_token, cart)
    cart_items = cart["items"] || []
    return { success: true } if cart_items.empty?

    update_cart_totals(cart_token, cart_items, use_subscription_prices: true)
    { success: true }
  rescue StandardError => e
    Rails.logger.error "Failed to update cart totals for cart #{cart_token}: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    { success: false, error: "cart_totals_update_failed", message: "Unable to update cart totals" }
  end
end
