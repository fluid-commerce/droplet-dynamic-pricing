class Callbacks::CartEmailOnCreateService < Callbacks::BaseService
  def call
    raise CallbackError, "Cart is blank" if cart.blank?

    email = cart["email"]
    raise CallbackError, "Email is blank" if email.blank?

    current_price_type = cart.dig("metadata", "price_type")

    if is_preferred_customer?(email)
      # Only log if there's a state change
      if current_price_type != PREFERRED_CUSTOMER_TYPE
        log_cart_pricing_event(
          event_type: "cart_created",
          preferred_applied: true,
          additional_data: { email: email }
        )
      end
      return result_success
    end

    # Only log if removing preferred pricing (state change)
    if current_price_type == PREFERRED_CUSTOMER_TYPE
      log_cart_pricing_event(
        event_type: "cart_created",
        preferred_applied: false,
        additional_data: { email: email }
      )
    end

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
