/**
 * `cart_item_added` — the callback that reprices every line on every
 * add-to-cart, and the highest-volume of the nine.
 *
 * Rails route: `POST /callbacks/cart_item_added`
 * (`Callbacks::CartItemAddedController`). The Rails path happened to match the
 * definition name here; two of the nine do not, which is why the table in
 * CUTOVER.md is the authority rather than the directory listing.
 *
 * Fails CLOSED — `CartItemCallbackSubscriber#deliver` discards the return value
 * of `Callback::Client.request`, so a refusal and a neutral 200 leave the cart
 * in exactly the same state, and only the refusal alerts anyone. See
 * src/lib/pricing/route.ts.
 */

import { callbackRoute, requireCallbackShape, cartItemAdded } from "@/lib/pricing";

export const POST = callbackRoute({
  definition: "cart_item_added",
  name: "cart-item-added",
  parse: (payload) => requireCallbackShape(payload, "cart_and_item"),
  run: cartItemAdded,
});
