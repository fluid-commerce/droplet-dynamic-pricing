# frozen_string_literal: true

class Callbacks::CartItemUpdatedController < Callbacks::BaseController
private

  def service_class
    Callbacks::CartItemUpdatedService
  end

  def permitted_params
    permitted = params.permit(
      :callback_name,
      :schema_version,
      :schema_hash,
      cart: {},
      cart_item: {},
      context: {},
      cart_item_updated: {}
    )

    cart = permitted.require(:cart)
    cart.require(:cart_token)
    cart.require(:company).require(:id)

    permitted.require(:cart_item)

    permitted
  end
end
