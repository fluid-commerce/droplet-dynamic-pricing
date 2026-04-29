class Callbacks::SubscriptionAddedService < Callbacks::BaseService
  def call
    raise CallbackError, "Cart is blank" if cart.blank?

    current_price_type = cart.dig("metadata", "price_type")

    if customer_logged_in?
      update_cart_metadata({ "price_type" => "preferred_customer" })
      update_cart_items_prices(cart_items_with_subscription_price) if cart_items.any?
    else
      update_cart_items_prices(subscription_items_only) if subscription_items_only.any?
    end

    if current_price_type != PREFERRED_CUSTOMER_TYPE && customer_logged_in?
      log_cart_pricing_event(
        event_type: "item_added",
        preferred_applied: true,
        additional_data: {
          callback: "subscription_added",
          items_updated: cart_items.count,
        }
      )
    end

    result_success
  rescue CallbackError => e
    handle_callback_error(e)
  end

private

  def subscription_items_only
    @subscription_items_only ||= cart_items.select { |item| item["subscription"] == true }.map do |item|
      {
        "id" => item["id"],
        "price" => item["subscription_price"] || item["price"],
      }
    end
  end
end
