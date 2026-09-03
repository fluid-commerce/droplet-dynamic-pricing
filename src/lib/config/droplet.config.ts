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
 * Callbacks live in the `callbacks` table, not here — an operator turns one on
 * in the admin UI without a deploy. See src/lib/callbacks and
 * CALLBACK_ROUTES in src/lib/pricing.
 */

import type { DropletConfig } from "./schema";

export const dropletConfig: DropletConfig = {
  webhooks: [
    {
      enabled: true,
      resource: "subscription",
      event: "started",
      description: "A customer's subscription began — promote them to preferred",
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
