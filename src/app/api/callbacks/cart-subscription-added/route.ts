/**
 * `cart_subscription_added`.
 *
 * Rails route: `POST /callbacks/subscription_added` — note the LOCAL name. The
 * Fluid definition is `cart_subscription_added`
 * (app/lib/callback_definitions/cart_subscription_added.yml), and this route is
 * named for the definition. Getting that backwards is the mistake zallevo #59
 * had to correct, and its symptom is not an error: Fluid simply stops calling.
 *
 * Fails CLOSED. Dispatched by `CartItemCallbackSubscriber` and by
 * `ManageSubscriptionAction#fire_subscription_callback`, both of which discard
 * the response.
 */

import { callbackRoute, requireCallbackShape, subscriptionAdded } from "@/lib/pricing";

export const POST = callbackRoute({
  definition: "cart_subscription_added",
  name: "cart-subscription-added",
  parse: (payload) => requireCallbackShape(payload, "cart_only"),
  run: subscriptionAdded,
});
