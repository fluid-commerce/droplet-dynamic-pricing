class Callbacks::CustomerLoggedInService < Callbacks::BaseService
  def call
    raise CallbackError, "Cart is blank" if cart.blank?
    raise CallbackError, "Email is blank" if customer_email.blank?

    raise CallbackError, "Customer is not logged in" unless customer_logged_in?

    # The cart is already paid for (or the order already exists): nothing left to
    # price, and writing now desyncs the order total from the captured amount
    # (CURRENT-3361).
    return result_success if cart_settled?

    # Enrollment carts and yoli-promos WHOLESALE-unlock carts are priced by the
    # BP wholesale droplet (STU2-2377, STU2-2964).
    return result_success if yield_to_enrollment_wholesale? || price_type_wholesale?

    is_preferred = is_preferred_customer?(customer_email)

    current_price_type = cart.dig("metadata", "price_type")

    if is_preferred
      sync_pcc_metafield(cart_customer_id)

      update_cart_metadata({ "price_type" => PREFERRED_CUSTOMER_TYPE })
      if cart_items.any?
        update_cart_items_prices(cart_items_with_subscription_price)
        update_cart_items_volumes(cart_items, mode: :subscription)
      end

      if current_price_type != PREFERRED_CUSTOMER_TYPE
        log_cart_pricing_event(
          event_type: "customer_logged_in",
          preferred_applied: true,
          additional_data: { email: customer_email, customer_id: cart_customer_id }
        )
      end

      return { success: true, metadata: { "price_type" => PREFERRED_CUSTOMER_TYPE } }
    end

    # `is_preferred = false` can mean "not preferred" or "we could not tell":
    # every lookup behind is_preferred_customer? rescues to false. Only the former
    # justifies stripping the discount off every line (CURRENT-3361).
    if current_price_type == PREFERRED_CUSTOMER_TYPE &&
       !has_another_subscription_in_cart? &&
       !preferred_lookup_failed?
      update_cart_metadata({ "price_type" => nil })
      if cart_items.any?
        update_cart_items_prices(cart_items_with_regular_price)
        update_cart_items_volumes(cart_items, mode: :regular)
      end

      log_cart_pricing_event(
        event_type: "customer_logged_in",
        preferred_applied: false,
        additional_data: { email: customer_email, customer_id: cart_customer_id, reason: "not_preferred" }
      )
    end

    result_success
  rescue CallbackError => e
    handle_callback_error(e)
  rescue StandardError => e
    Rails.logger.error "Error in CustomerLoggedInService: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    report_exception(e)
    { success: false, error: "unexpected_error", message: "An unexpected error occurred" }
  end

private

  def sync_pcc_metafield(customer_id)
    current_type = get_customer_type_from_metafields(customer_id)
    return if current_type == PREFERRED_CUSTOMER_TYPE

    update_pcc_metafield(customer_id, PREFERRED_CUSTOMER_TYPE)
    Rails.logger.info "[CustomerLoggedIn] Updated PCC metafield to preferred_customer for customer #{customer_id}"
  rescue StandardError => e
    Rails.logger.error "[CustomerLoggedIn] Failed to sync PCC metafield: #{e.message}"
  end
end
