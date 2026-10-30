/**
 * Droplet Uninstallation Handler
 *
 * Port of app/jobs/droplet_uninstalled_job.rb. Deletes the callback
 * registrations this droplet created for the company, drops their stored
 * digests, and marks the row uninstalled.
 *
 * The row is kept rather than deleted, exactly as Rails did: `events` has a
 * NOT NULL foreign key to it, and a reinstall is expected to find it again.
 */

import { z } from "zod";

import { prisma } from "@/lib/db";
import { createFluidClient } from "@/lib/fluid";
import {
  dropletConfig,
  cleanupAllFeatures,
  RAILS_WEBHOOK_PATHS,
  SUBSCRIPTION_CLEANUP_EVENTS,
} from "@/lib/config";

import { cleanupCallbacksForCompany } from "@/lib/callbacks";
import { findCompanyForPayload } from "./find-company";

const uninstallPayloadSchema = z.object({
  company: z.object({
    fluid_company_id: z.union([z.number(), z.string()]).optional(),
    company_droplet_uuid: z.string().optional(),
    droplet_installation_uuid: z.string().optional(),
  }),
});

export async function handleDropletUninstalled(
  payload: unknown,
): Promise<void> {
  const parsed = uninstallPayloadSchema.parse(payload);
  const company = await findCompanyForPayload(parsed);

  if (!company) {
    console.warn(
      "[DropletUninstalled] Company not found for payload:",
      JSON.stringify(parsed.company),
    );
    return;
  }

  // The row belongs to a newer installation, so this uninstall must not touch
  // it. The Rails app shares this table and matches on fluid_shop: reinstalling
  // the Rails droplet after this one (a rollback) writes Rails' dri onto the
  // same row and merges its callback ids into the list below. findCompanyForPayload
  // then falls back to fluid_company_id, and cleaning up here would delete the
  // Rails callbacks and mark the company uninstalled under it.
  //
  // Both values must be present and differ; anything else cleans up as before.
  // The same guard runs on the Rails side (DropletUninstalledJob).
  const uninstalledDri = parsed.company.droplet_installation_uuid;
  if (
    uninstalledDri &&
    company.dropletInstallationUuid &&
    uninstalledDri !== company.dropletInstallationUuid
  ) {
    console.warn(
      `[DropletUninstalled] Skipping cleanup for company ${company.id}: ` +
        `uninstall is for installation ${uninstalledDri}, but the company is ` +
        `now on ${company.dropletInstallationUuid}`,
    );
    return;
  }

  const installedCallbackIds = Array.isArray(company.installedCallbackIds)
    ? (company.installedCallbackIds as unknown[]).filter(
        (id): id is string => typeof id === "string",
      )
    : [];

  const client = createFluidClient(company.authenticationToken);

  try {
    await cleanupAllFeatures(client, dropletConfig);
  } catch (error) {
    console.error(
      "[DropletUninstalled] Feature cleanup failed:",
      error instanceof Error ? error.message : error,
    );
  }

  await cleanupRailsSubscriptionWebhooks(client);

  await cleanupCallbacksForCompany(
    client,
    company.id,
    installedCallbackIds,
    company.dropletInstallationUuid,
  );

  await prisma.company.update({
    where: { id: company.id },
    data: { uninstalledAt: new Date(), active: false },
  });

  console.log(`[DropletUninstalled] Company ${company.id} uninstalled`);
}

/**
 * Deletes subscription webhooks still registered against the RAILS app.
 *
 * `cleanupAllFeatures` matches on the exact urls THIS app registers, which is
 * what stops it deleting another droplet's webhook for the same
 * resource+event. During the migration window that is not enough: a company
 * installed by Rails has its five subscription webhooks on the Rails host, and
 * an uninstall handled by the Next app would leave all five behind, firing at a
 * droplet the company no longer has.
 *
 * The Rails origin is not guessed — it is `LEGACY_RAILS_ORIGIN`, set to the
 * same value `DropletInstalledJob#build_subscription_webhook_events` built
 * those urls from. Matching on origin AND path AND resource+event keeps the
 * "never delete another droplet's webhook" property intact.
 *
 * It was `Setting.host_server.base_url` until the settings table stopped being
 * an editable config surface. Env, because that is where this droplet's other
 * urls come from, and because a value that decides which webhooks get DELETED
 * should not be a text field on a screen every merchant can reach.
 *
 * Unset, this does nothing — which is the right answer once every company has
 * been installed by this app rather than by Rails, and the only answer for a
 * fresh deploy that never had a Rails era.
 *
 * `updated` is in the event list even though nothing registers it any more:
 * installs used to register `subscription.updated` at
 * `{base}/webhook/cart_item_updated`, a route this droplet never had, and any
 * survivor 404s on every dispatch.
 */
async function cleanupRailsSubscriptionWebhooks(
  client: ReturnType<typeof createFluidClient>,
): Promise<void> {
  const railsOrigin = (process.env.LEGACY_RAILS_ORIGIN ?? "")
    .trim()
    .replace(/\/$/, "");

  // No Rails era to clean up after.
  if (!railsOrigin) return;

  const railsPaths = new Set<string>([
    ...Object.values(RAILS_WEBHOOK_PATHS),
    // The dead `subscription.updated` registration, at the path it never had a
    // route for.
    "/webhook/cart_item_updated",
  ]);

  try {
    const webhooks = (await client.listWebhooks()).webhooks ?? [];
    for (const webhook of webhooks) {
      if (webhook.resource !== "subscription") continue;
      if (!SUBSCRIPTION_CLEANUP_EVENTS.includes(webhook.event ?? "")) continue;
      if (!webhook.url?.startsWith(`${railsOrigin}/`)) continue;
      if (!railsPaths.has(new URL(webhook.url).pathname)) continue;

      try {
        await client.deleteWebhook(String(webhook.id));
        console.log(
          `[DropletUninstalled] Deleted Rails-era subscription.${webhook.event} webhook ${webhook.id}`,
        );
      } catch (error) {
        console.error(
          `[DropletUninstalled] Failed to delete Rails-era webhook ${webhook.id}:`,
          error instanceof Error ? error.message : error,
        );
      }
    }
  } catch (error) {
    console.error(
      "[DropletUninstalled] Could not list webhooks for Rails-era cleanup:",
      error instanceof Error ? error.message : error,
    );
  }
}
