class Callbacks::SubscriptionAddedService < Callbacks::BaseService
  def call
    raise CallbackError, "Cart is blank" if cart.blank?

    update_cart_metadata({ "price_type" => "preferred_customer" })

    update_cart_items_prices(cart_items_with_subscription_price) if cart_items.any?

    result_success
  rescue CallbackError => e
    handle_callback_error(e)
  end
end
