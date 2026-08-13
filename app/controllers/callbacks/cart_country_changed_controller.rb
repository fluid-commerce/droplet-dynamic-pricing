# frozen_string_literal: true

class Callbacks::CartCountryChangedController < Callbacks::BaseController
private

  def service_class
    Callbacks::CartCountryChangedService
  end

  def permitted_params
    permitted = params.permit(
      :callback_name,
      :schema_version,
      :schema_hash,
      cart: {},
      context: {}
    )

    cart = permitted.require(:cart)
    cart.require(:cart_token)
    cart.require(:company).require(:id)

    permitted
  end
end
