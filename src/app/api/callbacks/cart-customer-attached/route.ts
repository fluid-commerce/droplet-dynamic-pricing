/**
 * `cart_customer_attached` — fires whenever a customer becomes bound to a
 * cart, including the "already logged in, entering the new checkout" case that
 * `cart_customer_logged_in` never covered (STU2-2531).
 *
 * Rails route: `POST /callbacks/cart_customer_attached`.
 *
 * The HIGH-TRAFFIC one of the customer-lifecycle three: its `order_completion`
 * trigger is roughly 39% of its volume, and the settled-cart guard is what
 * keeps that share from repricing carts that have already been charged
 * (CURRENT-3361).
 *
 * Fails CLOSED. `CartCustomerCallbackSubscriber#deliver` discards the
 * response.
 */

import { callbackRoute, requireCallbackShape, cartCustomerAttached } from "@/lib/pricing";

export const POST = callbackRoute({
  definition: "cart_customer_attached",
  name: "cart-customer-attached",
  parse: (payload) => requireCallbackShape(payload, "cart_with_customer"),
  run: cartCustomerAttached,
});
