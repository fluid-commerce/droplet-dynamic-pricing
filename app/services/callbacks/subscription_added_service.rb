class Callbacks::SubscriptionAddedService < Callbacks::BaseService
  def call
    cart = @callback_params[:cart]
    return { success: true } if cart.blank?

    cart_token, cart_items = extract_cart_token_and_items(cart)

    update_cart_metadata(cart_token, { "price_type" => "preferred_customer" })

    if cart_items.any?
      items_data = build_subscription_items_data(cart_items)
      update_cart_items_prices(cart_token, items_data)
    end

    { success: true }
  end

private

  def extract_cart_token_and_items(cart)
    cart_token = cart["cart_token"]
    cart_items = cart["items"] || []
    [ cart_token, cart_items ]
  end
end
