/**
 * `cart_item_updated`.
 *
 * Rails route: `POST /callbacks/cart_item_updated`.
 *
 * Fails CLOSED, for the same reason as `cart_item_added` — same subscriber,
 * same discarded return value.
 */

import { callbackRoute, requireCallbackShape, cartItemUpdated } from "@/lib/pricing";

export const POST = callbackRoute({
  definition: "cart_item_updated",
  name: "cart-item-updated",
  parse: (payload) => requireCallbackShape(payload, "cart_and_item"),
  run: cartItemUpdated,
});
