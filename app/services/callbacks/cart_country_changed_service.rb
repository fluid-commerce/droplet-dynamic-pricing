# frozen_string_literal: true

# Repairs the cart lines this droplet locked when the cart's country changes.
#
# Every price the droplet writes gets metadata.price_locked stamped on it, and Fluid
# skips locked lines when it reprices (ItemPricing#repriceable?), so a line written
# under the old country keeps its amount while the currency around it changes.
# Releasing the lock isn't the answer — Fluid would recompute from the catalog and
# drop the preferred-customer discount this droplet exists to apply. The writer is
# the only one who can correct a locked line.
#
# By the time this fires, core has already repriced every line it is allowed to
# touch, so the locked ones are all that is left behind — and they are all this
# service touches.
class Callbacks::CartCountryChangedService < Callbacks::BaseService
  def call
    raise CallbackError, "Cart is blank" if cart.blank?

    # The cart is already paid for (or the order already exists): nothing left to
    # price, and writing now desyncs the order total from the captured amount
    # (CURRENT-3361).
    return result_success if cart_settled?

    # Priced by the BP wholesale droplet (STU2-2377, STU2-2964).
    return result_success if yield_to_enrollment_wholesale? || price_type_wholesale?

    # Only the lines this droplet locked. Everything else core has already repriced
    # at the new country, and writing to it would lock a price Fluid set itself.
    locked = locked_cart_items
    return result_success if locked.empty?

    preferred = preferred_pricing_cart?
    if preferred
      update_cart_items_prices(cart_items_with_subscription_price(locked))
      update_cart_items_volumes(locked, mode: :subscription)
    else
      update_cart_items_prices(cart_items_with_regular_price(locked))
      update_cart_items_volumes(locked, mode: :regular)
    end

    log_cart_pricing_event(
      event_type: "country_changed",
      preferred_applied: preferred,
      additional_data: {
        callback: "cart_country_changed",
        country_code: country_code_from_context,
        previous_country_code: previous_country_code_from_context,
        items_updated: locked.count,
      }
    )

    return success_with_message("Cart repriced for the new country") unless preferred

    preferred_pricing_response(message: "Cart repriced for the new country")
  rescue CallbackError => e
    handle_callback_error(e)
  end

private

  # Which price to restore on the lines this droplet locked. Derived from the one
  # rule, not from the cart stamp: a cart stamped preferred whose subscription is
  # gone must come back at retail, same as everywhere else (CURRENT-3361).
  def preferred_pricing_cart?
    cart_qualifies_for_preferred_pricing?
  end

  def country_code_from_context
    callback_context["country_code"] || callback_context[:country_code] || cart_country
  end

  def previous_country_code_from_context
    callback_context["previous_country_code"] || callback_context[:previous_country_code]
  end
end
