/**
 * `cart_customer_logged_in`.
 *
 * Rails route: `POST /callbacks/customer_logged_in` — a LOCAL name. The Fluid
 * definition is `cart_customer_logged_in`.
 *
 * Fails CLOSED. Dispatched synchronously from
 * `Commerce::Cart#trigger_customer_logged_in_callback`, which discards the
 * response.
 */

import { callbackRoute, requireCallbackShape, customerLoggedIn } from "@/lib/pricing";

export const POST = callbackRoute({
  definition: "cart_customer_logged_in",
  name: "cart-customer-logged-in",
  parse: (payload) => requireCallbackShape(payload, "cart_with_email"),
  run: customerLoggedIn,
});
