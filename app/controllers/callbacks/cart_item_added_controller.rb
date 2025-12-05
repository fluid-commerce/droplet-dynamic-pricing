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

    cart = permitted.require(:cart)
    cart.require(:cart_token)
    cart.require(:email)
    cart.require(:company).require(:id)

    permitted.require(:cart_item)

    permitted
  end
end
