class Callbacks::SubscriptionAddedController < Callbacks::BaseController
private

  def service_class
    Callbacks::SubscriptionAddedService
  end

  def permitted_params
    permitted = params.permit(
      :callback_name,
      :schema_version,
      :schema_hash,
      cart: {},
      cart_item: {},
      context: {},
      subscription_added: {}
    )

    cart = permitted.require(:cart)
    cart.require(:cart_token)
    cart.require(:company).require(:id)

    permitted
  end
end
