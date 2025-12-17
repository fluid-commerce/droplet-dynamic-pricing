class Callbacks::CartItemAddedService < Callbacks::BaseService
  def call
    raise CallbackError, "Cart is blank" if cart.blank?
    raise CallbackError, "Cart item is blank" if cart_item.blank?

    price_type = cart.dig("metadata", "price_type")

    has_another_subscription = has_another_subscription_in_cart?

    if price_type != PREFERRED_CUSTOMER_TYPE && !has_another_subscription
      return { success: true, message: "Cart does not have preferred_customer pricing" }
    end

    update_cart_metadata({ "price_type" => PREFERRED_CUSTOMER_TYPE })
    update_item_to_subscription_price

    { success: true, message: "Cart item updated to subscription price successfully" }
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
end
