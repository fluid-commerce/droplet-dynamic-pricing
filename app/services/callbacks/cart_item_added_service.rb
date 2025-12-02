class Callbacks::CartItemAddedService < Callbacks::BaseService
  def call
    params = normalize_params
    cart, cart_item = extract_cart_and_item(params)

    return log_and_return("Cart or cart_item data is missing", success: false) if cart.blank? || cart_item.blank?

    price_type = cart.dig("metadata", "price_type")
    return log_and_return("Cart does not have preferred_customer pricing") unless price_type == PREFERRED_CUSTOMER_TYPE

    cart_token = cart["cart_token"]
    if cart_token.blank?
      Rails.logger.warn "Skipping cart update: missing cart_token for cart payload: #{cart.inspect}"
      return log_and_return("Cart token is missing, skipping update", success: true)
    end

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
    item_id = cart_item["id"]
    if item_id.blank?
      Rails.logger.error "Cannot update item price: missing item ID for cart #{cart_token}. Item: #{cart_item.inspect}"
      return { success: false, error: "missing_item_id", message: "Item ID is required" }
    end

    subscription_price = cart_item["subscription_price"]
    regular_price = cart_item["price"]
    final_price = subscription_price || regular_price

    if final_price.blank?
      Rails.logger.error "Cannot update item price: no price available for item #{item_id}
                                        in cart #{cart_token}. Item: #{cart_item.inspect}"

      return { success: false, error: "missing_item_price", message: "Item price is required" }
    end

    item_data = [ {
      "id" => item_id,
      "price" => final_price,
    } ]

    update_cart_items_prices(cart_token, item_data)

    { success: true }
  rescue StandardError => e
    Rails.logger.error "Failed to update item prices for cart #{cart_token}: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    { success: false, error: "item_price_update_failed", message: "Unable to update item prices" }
  end

  def update_cart_totals_with_subscription_prices(cart_token, cart)
    cart_items = cart["items"]

    if cart_items.nil?
      Rails.logger.warn "Skipping cart totals update: cart['items'] is missing for cart #{cart_token}"
      return { success: true }
    end

    unless cart_items.is_a?(Array)
      Rails.logger.error "Invalid cart items format: expected Array, got #{cart_items.class} for cart #{cart_token}.
                                                                                        Value: #{cart_items.inspect}"

      return { success: false, error: "invalid_cart_items_format", message: "Cart items must be an Array" }
    end

    if cart_items.empty?
      Rails.logger.debug "Skipping cart totals update: no items in cart #{cart_token}"

      return { success: true }
    end

    update_cart_totals(cart_token, cart_items, use_subscription_prices: true)

    { success: true }
  rescue StandardError => e
    Rails.logger.error "Failed to update cart totals for cart #{cart_token}: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    { success: false, error: "cart_totals_update_failed", message: "Unable to update cart totals" }
  end
end
