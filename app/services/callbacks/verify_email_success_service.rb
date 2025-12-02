class Callbacks::VerifyEmailSuccessService < Callbacks::BaseService
  def call
    email = @callback_params[:email] || @callback_params.dig("email")

    cart_token = @callback_params[:cart_token] ||
                 @callback_params.dig("cart_token") ||
                 @callback_params.dig(:cart, :cart_token) ||
                 @callback_params.dig("cart", "cart_token")

    return { success: true } if email.blank? || cart_token.blank?

    customer = get_customer_by_email(email)
    return { success: true } if customer.blank?

    customer_type = customer.dig("metadata", "customer_type") || customer.dig(:metadata, :customer_type)
    return { success: true, message: "Customer type is not set" } if customer_type.blank?

    if customer_type == "preferred_customer"
      update_cart_metadata(cart_token, { "price_type" => "preferred_customer" })
      Rails.logger.info "Cart metadata updated successfully for cart #{cart_token}"
    end

    { success: true }
  end
end
