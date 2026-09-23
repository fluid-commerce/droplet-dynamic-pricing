/**
 * Droplet configuration schema.
 *
 * Declares the per-company webhooks AND callbacks this droplet registers on
 * install, which is the fleet's pattern and now this droplet's.
 *
 * The Rails app this replaces kept its callback catalogue in the `callbacks`
 * table: synced from Fluid's definition list, edited in the admin UI, and read
 * by the install job, so an operator could turn a callback on without a deploy.
 * That flexibility bought nothing and cost a lot. The sync imported every
 * definition Fluid offers, including the ones this droplet has no handler for,
 * and enabling one of those registered a URL that 404s on every dispatch —
 * which is how TM3's `verify_email_success` registration came to exist. The row
 * was also droplet-global with no `company_id`, so the screen that edited it
 * changed every company's pricing at once.
 *
 * Declared in code, none of that is expressible: the list cannot drift from the
 * routes, a definition with no handler cannot be named, and changing a timeout
 * is a reviewed commit rather than a text field.
 *
 * **Dropzones** are still not here. The Rails template never registered any,
 * so nothing was ported. Fluid's `/api/drop_zones` endpoints are real and a
 * droplet forked from this template can add them; they are just not invented
 * here.
 */

import { z } from "zod";

export const webhookConfigSchema = z.object({
  enabled: z.boolean().default(true),
  resource: z.string().describe("Resource type (e.g. 'order', 'cart')"),
  event: z.string().describe("Event name (e.g. 'created', 'updated')"),
  description: z.string().optional(),
  /**
   * The path this webhook is delivered to, relative to FLUID_DROPLET_URL.
   *
   * The template registered everything at `/api/webhooks` and had no need for
   * this. THIS droplet gives each subscription event its own route, matching
   * Rails' five `/webhook/subscription_*` paths, because the five handlers do
   * genuinely different things and the event name alone does not distinguish
   * `started` (promote) from `cancelled` (maybe demote).
   *
   * It is also the discriminator the cleanup path matches on, so changing a
   * path here without re-registering leaves an orphan webhook at the old one.
   */
  path: z.string().default("/api/webhooks"),
});

export type WebhookConfig = z.infer<typeof webhookConfigSchema>;

export const callbackConfigSchema = z.object({
  enabled: z.boolean().default(true),
  /**
   * Fluid's own name for the callback definition, which is what a registration
   * is created against. It must be a key of CALLBACK_ROUTES — that table maps
   * it to the path this droplet answers on, and is the single place the two are
   * tied together.
   */
  definition_name: z.string(),
  description: z.string().optional(),
  /**
   * How long Fluid waits before abandoning the call and serving the cart
   * unchanged.
   *
   * Load-bearing, and not in the harmless direction: a pricing callback that
   * times out does NOT fail closed. Fluid keeps the price already on the cart,
   * so the shopper is served a stale price and nothing errors. Raising this
   * makes checkout slower; lowering it makes wrong prices more likely. 20 is
   * Fluid's own maximum and what the live Rails registrations use.
   */
  timeoutInSeconds: z.number().int().min(1).max(20).default(20),
});

export type CallbackConfig = z.infer<typeof callbackConfigSchema>;

export const dropletConfigSchema = z.object({
  webhooks: z.array(webhookConfigSchema).default([]),
  callbacks: z.array(callbackConfigSchema).default([]),
});

export type DropletConfig = z.infer<typeof dropletConfigSchema>;

export function validateConfig(config: unknown): DropletConfig {
  return dropletConfigSchema.parse(config);
}

export function filterEnabled<T extends { enabled: boolean }>(items: T[]): T[] {
  return items.filter((item) => item.enabled);
}
