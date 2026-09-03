/**
 * `cart_customer_detached` — a logout, back to guest.
 *
 * Rails route: `POST /callbacks/cart_customer_detached`.
 *
 * Fails CLOSED. Same subscriber as `cart_customer_attached`, same discarded
 * response.
 */

import { callbackRoute, requireCallbackShape, cartCustomerDetached } from "@/lib/pricing";

export const POST = callbackRoute({
  definition: "cart_customer_detached",
  name: "cart-customer-detached",
  parse: (payload) => requireCallbackShape(payload, "cart_only"),
  run: cartCustomerDetached,
});
