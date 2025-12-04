class Callbacks::SubscriptionRemovedController < Callbacks::BaseController
private

  def service_class
    Callbacks::SubscriptionRemovedService
  end

  def permitted_params
    permitted = params.permit(
      :callback_name,
      :schema_version,
      :schema_hash,
      cart: {},
      cart_item: {},
      context: {},
      subscription_removed: {}
    )

    cart = permitted.require(:cart)
    cart.require(:cart_token)
    cart.require(:email)
    cart.require(:company).require(:id)

    permitted
  end
end
