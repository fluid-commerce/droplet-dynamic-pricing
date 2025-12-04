class Callbacks::CartEmailOnCreateService < Callbacks::BaseService
  def call
    raise CallbackError, "Cart is blank" if cart.blank?

    email = cart["email"]
    raise CallbackError, "Email is blank" if email.blank?

    customer_type_result = fetch_and_validate_customer_type(email)
    raise CallbackError, "Customer type not found for #{email}" if customer_type_result[:success] == false

    customer_type = customer_type_result[:customer_type]
    return result_success if customer_type == PREFERRED_CUSTOMER_TYPE

    { success: true, message: "Customer type is '#{customer_type}', no special pricing needed" }
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
