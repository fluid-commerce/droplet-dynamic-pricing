/**
 * Droplet Configuration
 *
 * The per-company webhooks registered when a company installs this droplet.
 * These are separate from the droplet-level `droplet.installed` /
 * `droplet.uninstalled` webhooks, which are created once by the admin
 * dashboard's "Create Droplet" action — see src/lib/use-cases/droplet.ts.
 *
 * Port of `DropletInstalledJob#build_subscription_webhook_events`. Five events,
 * five paths, matching the five Rails `POST /webhook/subscription_*` routes.
 *
 * ## `subscription.updated` is deliberately absent
 *
 * Rails registered it at `{base}/webhook/cart_item_updated` — a path this
 * droplet has never routed, because `cart_item_updated` is a CALLBACK at
 * `/callbacks/cart_item_updated`, not a webhook. Every `subscription.updated`
 * therefore fired into a 404. It was removed from the install job on `main`
 * before this migration; the UNINSTALL filter still lists `updated` so that any
 * registration left over from before is cleaned up.
 *
 * Callbacks are declared here too, alongside the webhooks. They used to live in
 * the `callbacks` table, synced from Fluid and edited in the admin UI; see
 * src/lib/config/schema.ts for why that stopped. The path each one is served at
 * comes from CALLBACK_ROUTES in src/lib/pricing, which stays the single owner
 * of the definition-name -> path mapping.
 */

import type { DropletConfig } from "./schema";

export const dropletConfig: DropletConfig = {
  webhooks: [
    {
      enabled: true,
      resource: "subscription",
      event: "started",
      description:
        "A customer's subscription began — promote them to preferred",
      path: "/api/webhooks/subscription-started",
    },
    {
      enabled: true,
      resource: "subscription",
      event: "paused",
      description:
        "A subscription was paused — demote unless another subscription or an Exigo autoship remains",
      path: "/api/webhooks/subscription-paused",
    },
    {
      enabled: true,
      resource: "subscription",
      event: "cancelled",
      description:
        "A subscription was cancelled — demote unless another subscription or an Exigo autoship remains",
      path: "/api/webhooks/subscription-cancelled",
    },
    {
      enabled: true,
      resource: "subscription",
      event: "resumed",
      description: "A paused subscription resumed — promote back to preferred",
      path: "/api/webhooks/subscription-resumed",
    },
    {
      enabled: true,
      resource: "subscription",
      event: "reactivated",
      description:
        "A cancelled subscription was reactivated — promote back to preferred",
      path: "/api/webhooks/subscription-reactivated",
    },
  ],

  /**
   * The eight callbacks this droplet registers, in the order CALLBACK_ROUTES lists
   * them. Every one is registered at install against the path that table gives
   * it, on FLUID_DROPLET_URL.
   *
   * `cart_customer_logged_in` is not one of them. Core fires it only on
   * magic-link login, and the same action fires `cart_customer_attached` right
   * after, which reprices the same cart.
   *
   * There is no ninth: a definition Fluid offers but this droplet has no route
   * for cannot be named here, because `activeCallbacks` resolves the path
   * through CALLBACK_ROUTES and refuses a name that is not in it.
   */
  callbacks: [
    {
      enabled: true,
      definition_name: "cart_item_added",
      description: "Price a line as it is added to the cart",
      timeoutInSeconds: 20,
    },
    {
      enabled: true,
      definition_name: "cart_item_updated",
      description: "Re-price a line whose quantity or variant changed",
      timeoutInSeconds: 20,
    },
    {
      enabled: true,
      definition_name: "cart_subscription_added",
      description: "Re-price the cart once a line becomes a subscription",
      timeoutInSeconds: 20,
    },
    {
      enabled: true,
      definition_name: "cart_subscription_removed",
      description: "Re-price the cart once a line stops being a subscription",
      timeoutInSeconds: 20,
    },
    {
      enabled: true,
      definition_name: "cart_email_on_create",
      description: "Resolve the buyer from the email typed at checkout",
      timeoutInSeconds: 20,
    },
    {
      enabled: true,
      definition_name: "cart_customer_attached",
      description: "Re-price once a customer is attached to the cart",
      timeoutInSeconds: 20,
    },
    {
      enabled: true,
      definition_name: "cart_customer_detached",
      description: "Re-price back to retail once the customer is removed",
      timeoutInSeconds: 20,
    },
    {
      enabled: true,
      definition_name: "cart_country_changed",
      description: "Re-price for the destination country's price list",
      timeoutInSeconds: 20,
    },
  ],
};

/**
 * The events uninstall cleans up.
 *
 * A SUPERSET of what install registers: `updated` is included because installs
 * used to register it at a path this droplet never routed, so any survivor
 * 404s on every dispatch for a company that no longer has the droplet.
 */
export const SUBSCRIPTION_CLEANUP_EVENTS = [
  "started",
  "paused",
  "cancelled",
  "resumed",
  "reactivated",
  "updated",
];

/**
 * The RAILS path each subscription webhook is delivered to today, keyed
 * `resource.event`, for the rollback direction of scripts/cutover.ts.
 */
export const RAILS_WEBHOOK_PATHS: Readonly<Record<string, string>> =
  Object.freeze({
    "subscription.started": "/webhook/subscription_started",
    "subscription.paused": "/webhook/subscription_paused",
    "subscription.cancelled": "/webhook/subscription_cancelled",
    "subscription.resumed": "/webhook/subscription_resumed",
    "subscription.reactivated": "/webhook/subscription_reactivated",
  });
