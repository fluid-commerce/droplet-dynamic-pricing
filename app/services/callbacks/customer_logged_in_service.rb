class Callbacks::CustomerLoggedInService < Callbacks::BaseService
  def call
    raise CallbackError, "Cart is blank" if cart.blank?
    raise CallbackError, "Email is blank" if customer_email.blank?

    raise CallbackError, "Customer is not logged in" unless customer_logged_in?

    # Enrollment carts and yoli-promos WHOLESALE-unlock carts are priced by the
    # BP wholesale droplet (STU2-2377, STU2-2964). Checked before the lookups below
    # so those carts still cost us no API calls.
    return result_success if yield_to_enrollment_wholesale? || price_type_wholesale?

    is_preferred = cart_qualifies_for_preferred_pricing?

    current_price_type = cart.dig("metadata", "price_type")

    # customer_type is a CUSTOMER resource, not a cart one, so the settled-cart
    # guard below does not apply to it. Keep it above the guard: order_completion
    # is ~39% of cart_customer_attached traffic and is the moment a guest-checkout
    # customer first exists, so gating this would delay the stamp on most guest
    # orders for no safety gain (CURRENT-3361).
    sync_pcc_metafield(cart_customer_id) if is_preferred

    # Everything past here writes to the cart, or claims a cart state that no
    # longer exists. The cart is already paid for (or the order already exists):
    # writing now desyncs the order total from the captured amount (CURRENT-3361).
    return result_success if cart_settled?

    if is_preferred
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
    # every lookup behind the rule rescues to false. Only the former justifies
    # stripping the discount off every line. The stamp is required too: revert
    # only pricing this droplet applied (CURRENT-3361).
    if current_price_type == PREFERRED_CUSTOMER_TYPE && !preferred_lookup_failed?
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
