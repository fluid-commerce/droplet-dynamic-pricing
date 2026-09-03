/**
 * `cart_subscription_removed`.
 *
 * Rails route: `POST /callbacks/subscription_removed` — again a LOCAL name; the
 * definition is `cart_subscription_removed`.
 *
 * Fails CLOSED. `ManageSubscriptionAction` discards the response.
 */

import { callbackRoute, requireCallbackShape, subscriptionRemoved } from "@/lib/pricing";

export const POST = callbackRoute({
  definition: "cart_subscription_removed",
  name: "cart-subscription-removed",
  parse: (payload) => requireCallbackShape(payload, "cart_only"),
  run: subscriptionRemoved,
});
