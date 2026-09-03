/**
 * Droplet configuration schema.
 *
 * Declares the per-company webhooks this droplet registers on install.
 *
 * Two things that belong in a droplet config are deliberately NOT here:
 *
 *  - **Callbacks.** The Rails app this replaces kept its callback catalogue in
 *    the `callbacks` table — synced from Fluid's definition list and edited in
 *    the admin UI — and registration reads from that table so an operator can
 *    turn a callback on without a deploy. Duplicating the list in code would
 *    create two sources of truth that disagree the moment someone uses the UI.
 *    See src/lib/callbacks.
 *  - **Dropzones.** The Rails template never registered any, so nothing was
 *    ported. Fluid's `/api/drop_zones` endpoints are real and a droplet forked
 *    from this template can add them; they are just not invented here.
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

export const dropletConfigSchema = z.object({
  webhooks: z.array(webhookConfigSchema).default([]),
});

export type DropletConfig = z.infer<typeof dropletConfigSchema>;

export function validateConfig(config: unknown): DropletConfig {
  return dropletConfigSchema.parse(config);
}

export function filterEnabled<T extends { enabled: boolean }>(items: T[]): T[] {
  return items.filter((item) => item.enabled);
}
