class Callbacks::SubscriptionRemovedController < Callbacks::BaseController
private

  def service_class
    Callbacks::SubscriptionRemovedService
  end

  def permitted_params
    params.permit(
      :callback_name,
      :schema_version,
      :schema_hash,
      cart: {},
      cart_item: {},
      context: {},
      subscription_removed: {}
    )
  end
end
