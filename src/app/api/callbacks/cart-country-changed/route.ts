/**
 * `cart_country_changed` — repairs the lines this droplet LOCKED when a
 * cart's country changes.
 *
 * Rails route: `POST /callbacks/cart_country_changed`.
 *
 * The safest of the nine to cut over first, and CUTOVER.md says so: it is
 * dispatched with `notify` rather than `request`
 * (`UpdateCountryAction#notify_country_changed`), so it runs on a thread pool
 * and its response is never read — not even on the shopper's request thread. It
 * fires only on a real country transition and touches only lines this droplet
 * locked.
 *
 * Fails CLOSED, which for an async dispatch costs nothing at all and still
 * produces the `rejected` log line an alert can be built on.
 */

import { callbackRoute, requireCallbackShape, cartCountryChanged } from "@/lib/pricing";

export const POST = callbackRoute({
  definition: "cart_country_changed",
  name: "cart-country-changed",
  parse: (payload) => requireCallbackShape(payload, "cart_only"),
  run: cartCountryChanged,
});
