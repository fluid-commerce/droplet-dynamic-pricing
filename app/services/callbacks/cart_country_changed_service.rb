# frozen_string_literal: true

# Repairs the cart lines this droplet locked when the cart's country changes.
#
# Every price the droplet writes goes through Fluid's update_cart_items_prices,
# which stamps metadata.price_locked on the line. Fluid then skips locked lines
# when it reprices (ItemPricing#repriceable?), so a line written under the old
# country keeps its amount while the currency around it changes — a PH cart
# showing the US figure with a peso sign. Releasing the lock is not the answer:
# Fluid would recompute from the catalog and drop the preferred-customer discount
# this droplet exists to apply. The writer is the only one who can correct a
# locked line, so Fluid tells us the country moved and we rewrite them.
#
# By the time this fires, core has already cleared ship_to/bill_to and repriced
# every unlocked line at the new country, so the payload's subscription_price is
# the new country's figure. The locked lines are the only ones left behind.
class Callbacks::CartCountryChangedService < Callbacks::BaseService
  def call
    raise CallbackError, "Cart is blank" if cart.blank?

    # Enrollment carts and yoli-promos WHOLESALE-unlock carts are priced by the
    # BP wholesale droplet (STU2-2377, STU2-2964).
    return result_success if yield_to_enrollment_wholesale? || price_type_wholesale?

    return result_success if cart_items.empty?

    # Same gate as the item callbacks: already stamped, or qualifying now
    # (STU2-2531). A cart that was never preferred has no price this droplet
    # wrote, so it has no locked line to repair and core's own reprice is
    # already correct — writing here would only lock a price Fluid set itself.
    unless preferred_pricing_cart?
      return { success: true, message: "Cart does not have preferred_customer pricing" }
    end

    update_cart_items_prices(cart_items_with_subscription_price)
    update_cart_items_volumes(cart_items, mode: :subscription)

    log_cart_pricing_event(
      event_type: "country_changed",
      preferred_applied: true,
      additional_data: {
        callback: "cart_country_changed",
        country_code: country_code_from_context,
        previous_country_code: previous_country_code_from_context,
        items_updated: cart_items.count,
      }
    )

    preferred_pricing_response(message: "Cart repriced for the new country")
  rescue CallbackError => e
    handle_callback_error(e)
  end

private

  def preferred_pricing_cart?
    cart.dig("metadata", "price_type") == PREFERRED_CUSTOMER_TYPE ||
      cart_qualifies_for_preferred_pricing?
  end

  def callback_context
    callback_params[:context] || {}
  end

  def country_code_from_context
    callback_context["country_code"] || callback_context[:country_code] || cart_country
  end

  def previous_country_code_from_context
    callback_context["previous_country_code"] || callback_context[:previous_country_code]
  end
end
