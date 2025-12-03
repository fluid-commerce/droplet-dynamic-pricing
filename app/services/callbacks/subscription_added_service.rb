class Callbacks::SubscriptionAddedService < Callbacks::BaseService
  def call
    raise CallbackError, "Cart is blank" if cart.blank?

    update_cart_metadata({ "price_type" => "preferred_customer" })

    if cart_items.any?
      all_items_data = build_subscription_items_data
      update_cart_items_prices(all_items_data)
    end

    result_success
  rescue CallbackError => e
    handle_callback_error(e)
  end
end
