class Callbacks::CartItemAddedService < Callbacks::BaseService
  def call
    raise CallbackError, "Cart is blank" if cart.blank?
    raise CallbackError, "Cart item is blank" if cart_item.blank?

    price_type = cart.dig("metadata", "price_type")

    if item_has_subscription? && price_type != PREFERRED_CUSTOMER_TYPE
      update_cart_metadata({ "price_type" => PREFERRED_CUSTOMER_TYPE })
      update_all_items_to_subscription_price
      return { success: true, message: "Cart updated to preferred_customer pricing due to subscription item" }
    end

    if price_type == PREFERRED_CUSTOMER_TYPE
      update_item_to_subscription_price
      return { success: true, message: "Cart item updated to subscription price successfully" }
    end

    { success: true, message: "Cart does not have preferred_customer pricing" }
  rescue CallbackError => e
    handle_callback_error(e)
  rescue StandardError => e
    Rails.logger.error "Unexpected error in CartItemAddedService: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    { success: false, error: "unexpected_error", message: "An unexpected error occurred" }
  end

private

  def cart_item
    @cart_item ||= callback_params[:cart_item]
  end

  def item_has_subscription?
    cart_item["subscription"] == true
  end

  def update_item_to_subscription_price
    item_id = cart_item["id"]
    raise CallbackError, "Item ID is required" if item_id.blank?

    subscription_price = cart_item["subscription_price"]
    regular_price = cart_item["price"]
    final_price = subscription_price || regular_price

    raise CallbackError, "Item price is not present in cart item" if final_price.blank?

    item_data = [ {
      "id" => item_id,
      "price" => final_price,
    } ]

    update_cart_items_prices(item_data)
  end

  def update_all_items_to_subscription_price
    return if cart_items.empty?

    update_cart_items_prices(cart_items_with_subscription_price)
  end
end
