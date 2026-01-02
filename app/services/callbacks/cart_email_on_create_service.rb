class Callbacks::CartEmailOnCreateService < Callbacks::BaseService
  def call
    raise CallbackError, "Cart is blank" if cart.blank?

    email = cart["email"]
    raise CallbackError, "Email is blank" if email.blank?

    return result_success if is_preferred_customer?(email)

    { success: true, message: "Regular customer, no special pricing needed" }
  rescue CallbackError => e
    handle_callback_error(e)
  rescue StandardError => e
    Rails.logger.error "Error in CartEmailOnCreateService: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    raise e
  end

private

  def result_success
    {
      success: true,
      metadata: { "price_type" => PREFERRED_CUSTOMER_TYPE },
    }
  end
end
