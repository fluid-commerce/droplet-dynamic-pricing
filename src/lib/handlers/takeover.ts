/**
 * Taking a company over from the Rails droplet.
 *
 * The Rails droplet and this one are two droplets in Fluid that share one
 * database, and both match a company on `fluid_shop`. Installing this droplet
 * on a company that still has the Rails one used to leave both live:
 *
 *  - Fluid called BOTH droplets' pricing callbacks on every cart event, and
 *    both apps wrote prices;
 *  - both apps' subscription webhooks fired;
 *  - uninstalling Rails afterwards found the shared row and deleted THIS
 *    installation's callbacks and webhooks, then marked the company
 *    uninstalled under it.
 *
 * So once this installation's own callbacks are registered, the previous
 * droplet's callbacks are removed and its installation is uninstalled in
 * Fluid. Every step logs and carries on. A failure leaves Rails still
 * answering next to this app — the state before this existed — never a
 * company with no pricing at all.
 *
 * The Rails uninstall that the last step triggers is safe only because
 * DropletUninstalledJob skips a company whose row now carries a different
 * `droplet_installation_uuid`. That guard must be deployed before this is.
 */

import { createFluidClient, FluidResourceNotFoundError } from "@/lib/fluid";
import { RAILS_WEBHOOK_PATHS } from "@/lib/config";

type FluidClient = ReturnType<typeof createFluidClient>;

export interface PreviousInstallation {
  /** The other droplet's uuid — what identifies its live installation in Fluid. */
  dropletUuid: string;
  /** The dri the row recorded. Can be stale or missing; only a fallback. */
  dri: string | null;
  authenticationToken: string;
  installedCallbackIds: string[];
}

interface ExistingCompany {
  dropletInstallationUuid: string | null;
  companyDropletUuid: string | null;
  authenticationToken: string;
  installedCallbackIds: unknown;
  uninstalledAt: Date | null;
}

/**
 * The live installation of ANOTHER droplet that this install is replacing, or
 * null.
 *
 * Keyed on the droplet uuid, not the row's dri. Long-lived Rails rows were
 * found carrying no dri or a stale one — Yoli has fourteen uninstalled
 * installations of the Rails droplet behind its active one — so requiring a
 * current dri here meant the takeover silently never ran for them.
 *
 * A reinstall or redelivery of this droplet carries this droplet's own uuid,
 * so it never matches. Neither does a row whose other droplet is already
 * uninstalled.
 */
export function previousInstallationOf(
  existing: ExistingCompany | null,
  incoming: { droplet_uuid: string; droplet_installation_uuid?: string },
): PreviousInstallation | null {
  if (!existing || existing.uninstalledAt) return null;
  if (!existing.companyDropletUuid) return null;
  if (existing.companyDropletUuid === incoming.droplet_uuid) return null;
  if (
    existing.dropletInstallationUuid &&
    existing.dropletInstallationUuid === incoming.droplet_installation_uuid
  ) {
    return null;
  }

  return {
    dropletUuid: existing.companyDropletUuid,
    dri: existing.dropletInstallationUuid || null,
    authenticationToken: existing.authenticationToken,
    installedCallbackIds: stringIds(existing.installedCallbackIds),
  };
}

export function stringIds(value: unknown): string[] {
  return Array.isArray(value)
    ? value.filter((id): id is string => typeof id === "string")
    : [];
}

/**
 * Removes the previous droplet's callbacks and webhooks, then uninstalls its
 * live installation(s).
 *
 * Returns the callback uuids that could NOT be deleted, so the caller keeps
 * them on the company and this app's own uninstall still tries them later.
 */
export async function takeOverPreviousInstallation(
  client: FluidClient,
  previous: PreviousInstallation,
  ownDri: string | null,
): Promise<{ undeletedCallbackIds: string[] }> {
  console.log(
    `[Takeover] Replacing droplet ${previous.dropletUuid} ` +
      `(row dri ${previous.dri ?? "none"}, ` +
      `${previous.installedCallbackIds.length} recorded callback registration(s))`,
  );

  // With THIS installation's token: core scopes registration deletes to the
  // company, not to the installation that created them. Stale ids 404, which
  // counts as done.
  const undeletedCallbackIds: string[] = [];
  for (const uuid of previous.installedCallbackIds) {
    try {
      await client.deleteCallback(uuid);
    } catch (error) {
      if (error instanceof FluidResourceNotFoundError) continue;
      undeletedCallbackIds.push(uuid);
      console.error(
        `[Takeover] Could not delete callback registration ${uuid}:`,
        error instanceof Error ? error.message : error,
      );
    }
  }

  // With the PREVIOUS token: core lets a droplet token delete only webhooks
  // its own installation owns, so this cannot reach another droplet's webhook
  // even where the path filter below would match it. A stale token just fails
  // here; the uninstall below still removes the webhooks the live installation
  // owns.
  await deleteRailsSubscriptionWebhooks(
    createFluidClient(previous.authenticationToken),
  );

  // Last, so core's cleanup of everything the installation owns — its
  // callback registrations and webhooks — runs only once this app is already
  // serving the company.
  for (const dri of await liveInstallationsOf(client, previous, ownDri)) {
    try {
      await client.uninstallDropletInstallation(dri);
      console.log(`[Takeover] Uninstalled ${dri}`);
    } catch (error) {
      if (!(error instanceof FluidResourceNotFoundError)) {
        console.error(
          `[Takeover] Could not uninstall ${dri}; it stays installed in Fluid:`,
          error instanceof Error ? error.message : error,
        );
      }
    }
  }

  return { undeletedCallbackIds };
}

/**
 * The previous droplet's installations Fluid still has live on this company.
 *
 * Asked of Fluid rather than read off the row, because the row's dri can be
 * stale. Falls back to the row's dri only when the listing itself fails.
 */
async function liveInstallationsOf(
  client: FluidClient,
  previous: PreviousInstallation,
  ownDri: string | null,
): Promise<string[]> {
  try {
    const { droplet_installations: installations = [] } =
      await client.listDropletInstallations();
    const live = installations
      .filter(
        (installation) =>
          installation.droplet_uuid === previous.dropletUuid &&
          installation.uuid !== ownDri &&
          installation.active !== false,
      )
      .map((installation) => installation.uuid);

    if (live.length === 0) {
      console.log(
        `[Takeover] Fluid lists no live installation of ${previous.dropletUuid}`,
      );
    }
    return live;
  } catch (error) {
    console.error(
      "[Takeover] Could not list droplet installations; falling back to the row's dri:",
      error instanceof Error ? error.message : error,
    );
    return previous.dri && previous.dri !== ownDri ? [previous.dri] : [];
  }
}

async function deleteRailsSubscriptionWebhooks(
  previousClient: FluidClient,
): Promise<void> {
  const railsPaths = new Set<string>([
    ...Object.values(RAILS_WEBHOOK_PATHS),
    // The dead subscription.updated registration older installs left behind.
    "/webhook/cart_item_updated",
  ]);

  try {
    const webhooks = (await previousClient.listWebhooks()).webhooks ?? [];
    for (const webhook of webhooks) {
      if (webhook.resource !== "subscription" || !webhook.url) continue;

      let pathname: string;
      try {
        pathname = new URL(webhook.url).pathname;
      } catch {
        continue;
      }
      if (!railsPaths.has(pathname)) continue;

      try {
        await previousClient.deleteWebhook(String(webhook.id));
        console.log(
          `[Takeover] Deleted Rails subscription.${webhook.event} webhook ${webhook.id}`,
        );
      } catch (error) {
        console.error(
          `[Takeover] Could not delete Rails webhook ${webhook.id}:`,
          error instanceof Error ? error.message : error,
        );
      }
    }
  } catch (error) {
    console.error(
      "[Takeover] Could not list webhooks with the previous installation's token:",
      error instanceof Error ? error.message : error,
    );
  }
}
