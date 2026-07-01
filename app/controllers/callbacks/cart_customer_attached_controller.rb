class Callbacks::CartCustomerAttachedController < Callbacks::BaseController
private

  def service_class
    Callbacks::CartCustomerAttachedService
  end

  def permitted_params
    permitted = params.permit(
      :callback_name,
      :schema_version,
      :schema_hash,
      cart: {},
      customer: {},
      context: {},
    )

    cart = permitted.require(:cart)
    cart.require(:cart_token)
    cart.require(:company).require(:id)

    permitted
  end
end
