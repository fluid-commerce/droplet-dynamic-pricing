class Callbacks::CartItemAddedController < Callbacks::BaseController
private

  def service_class
    Callbacks::CartItemAddedService
  end

  def permitted_params
    permitted = params.permit(
      :callback_name,
      :schema_version,
      :schema_hash,
      cart: {},
      cart_item: {},
      context: {},
      cart_item_added: {}
    )

    # A batched callback (Fluid's BATCH_CART_ITEM_CALLBACKS) carries the added
    # items as a top-level array of item objects. permit's empty-hash filter
    # only passes hashes, so the array is permitted per element — the same
    # accept-anything trust the cart and cart_item objects already get.
    batch_items = params[:cart_items]
    permitted[:cart_items] = batch_items.map { |item| item.permit!.to_h } if batch_items.is_a?(Array)

    cart = permitted.require(:cart)
    cart.require(:cart_token)
    cart.require(:company).require(:id)

    permitted.require(:cart_item)

    permitted
  end
end
