class Callbacks::CartEmailOnCreateService < Callbacks::BaseService
  def call
    raise CallbackError, "Cart is blank" if cart.blank?

    email = cart["email"]
    raise CallbackError, "Email is blank" if email.blank?

    current_price_type = cart.dig("metadata", "price_type")

    preferred = customer_logged_in? && is_preferred_customer?(email)

    if preferred
      sync_pcc_metafield

      if current_price_type != PREFERRED_CUSTOMER_TYPE
        log_cart_pricing_event(
          event_type: "cart_created",
          preferred_applied: true,
          additional_data: { email: email }
        )
      end
      return result_success
    end

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

  def sync_pcc_metafield
    return if cart_customer_id.blank?

    current_type = get_customer_type_from_metafields(cart_customer_id)
    return if current_type == PREFERRED_CUSTOMER_TYPE

    update_pcc_metafield(cart_customer_id, PREFERRED_CUSTOMER_TYPE)
    Rails.logger.info "[CartEmailOnCreate] Updated PCC metafield to preferred_customer for customer #{cart_customer_id}"
  rescue StandardError => e
    Rails.logger.error "[CartEmailOnCreate] Failed to sync PCC metafield: #{e.message}"
  end

  def result_success
    {
      success: true,
      metadata: { "price_type" => PREFERRED_CUSTOMER_TYPE },
    }
  end
end
