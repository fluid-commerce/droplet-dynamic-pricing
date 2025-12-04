class Callbacks::CartEmailOnCreateController < Callbacks::BaseController
private

  def service_class
    Callbacks::CartEmailOnCreateService
  end

  def permitted_params
    permitted = params.permit(
      :callback_name,
      :schema_version,
      :schema_hash,
      cart: {}
    )

    cart = permitted.require(:cart)
    cart.require(:email)
    cart.require(:company).require(:id)

    permitted
  end
end
