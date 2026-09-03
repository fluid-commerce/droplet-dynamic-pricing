/**
 * `subscription.resumed` webhook.
 *
 * Rails route: `POST /webhook/subscription_resumed`.
 * Next route:  `POST /api/webhooks/subscription-resumed`.
 *
 * The URL is registered per company at install time from
 * src/lib/config/droplet.config.ts, so a cutover moves it by re-registering the
 * webhook — see CUTOVER.md.
 */

import { subscriptionWebhookRoute } from "@/lib/webhooks/route";

export const POST = subscriptionWebhookRoute("resumed");
