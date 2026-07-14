# frozen_string_literal: true

class Callbacks::CartItemUpdatedService < Callbacks::BaseService
  def call
    raise CallbackError, "Cart is blank" if cart.blank?
    raise CallbackError, "Cart item is blank" if cart_item.blank?

    # Enrollment carts are priced by the BP wholesale droplet (STU2-2377).
    return result_success if yield_to_enrollment_wholesale?

    current_price_type = cart.dig("metadata", "price_type")

    # Same widened gate as CartItemAddedService: preferred applies when already
    # stamped OR the cart qualifies now (subscription line, or a customer with an
    # active subscription), so a preferred customer keeps the discount even if
    # the stamp is missing on this payload (STU2-2531).
    unless current_price_type == PREFERRED_CUSTOMER_TYPE || cart_qualifies_for_preferred_pricing?
      return { success: true, message: "Cart does not have preferred_customer pricing" }
    end

    # Re-affirm the preferred_customer slug alongside the reprice so an item
    # update can't leave the cart with subscription prices but a retail
    # price_type. See CartItemAddedService for the two-channel rationale.
    update_item_to_subscription_price
    update_cart_metadata({ "price_type" => PREFERRED_CUSTOMER_TYPE })

    preferred_pricing_response(message: "Item updated callback processed successfully")
  rescue CallbackError => e
    handle_callback_error(e)
  rescue StandardError => e
    Rails.logger.error "Unexpected error in CartItemUpdatedService: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    report_exception(e)
    { success: false, error: "unexpected_error", message: "An unexpected error occurred" }
  end
end
