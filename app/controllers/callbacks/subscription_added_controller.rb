class Callbacks::SubscriptionAddedController < Callbacks::BaseController
private

  def service_class
    Callbacks::SubscriptionAddedService
  end

  def permitted_params
    params.require(:cart).require(:cart_token)

    params.permit(
      :callback_name,
      :schema_version,
      :schema_hash,
      cart: {},
      cart_item: {},
      context: {},
      subscription_added: {}
    )
  end
end
