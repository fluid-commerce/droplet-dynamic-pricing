# frozen_string_literal: true

# Handles Fluid's `cart_customer_attached` callback, which fires whenever a
# customer becomes bound to a cart (cart_create, session_inherited,
# checkout_entry, magic_link, mfa_login, order_completion) — including the
# "already logged in, entering the new checkout" case that `customer_logged_in`
# never covered (STU2-2531).
#
# The pricing/volume behaviour is identical to CustomerLoggedInService, so we
# inherit it. The only difference is that `cart_customer_attached` ships the
# bound `customer` object in the payload, so we fall back to its email when the
# cart itself doesn't carry one yet.
class Callbacks::CartCustomerAttachedService < Callbacks::CustomerLoggedInService
private

  def customer_email
    @customer_email ||= cart&.dig("email").presence ||
                        callback_params.dig(:customer, "email") ||
                        callback_params.dig("customer", "email")
  end
end
