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

    batch_items = params[:cart_items]
    permitted[:cart_items] = batch_items.map { |item| item.permit!.to_h } if batch_items.is_a?(Array)

    cart = permitted.require(:cart)
    cart.require(:cart_token)
    cart.require(:company).require(:id)

    permitted
  end
end
