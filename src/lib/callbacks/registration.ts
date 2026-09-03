/**
 * Registering this droplet's callbacks with Fluid, for one installation.
 *
 * Port of DropletInstalledJob#register_active_callbacks, with the one thing
 * the Ruby version did not do: persisting the verification token.
 *
 * Fluid issues `verification_token` ONLY in the create response — the sole
 * writer is `before_create :set_tokens` on Callback::Registration, and the
 * update action refuses the field, so it cannot be re-read or rotated later.
 * Discarding it leaves a live registration that this droplet can never verify,
 * and because callback routes fail open, the symptom is silence. So: capture
 * it, store only `tokenDigest(...)`, and if either step is impossible, delete
 * the registration that was just created.
 */

import { tokenDigest } from "@fluid-app/droplet-sdk";

import type { FluidClient } from "@/lib/fluid";
import { prisma } from "@/lib/db";
// Imported from the table module rather than from @/lib/pricing, which
// re-exports the route factory and would make this a cycle.
import {
  CALLBACK_ROUTES,
  RAILS_CALLBACK_PATHS,
} from "@/lib/pricing/routes-table";
import { hostServerBaseUrl } from "@/lib/settings";
import { callbackStore } from "./store";

export interface CallbackRegistrationResults {
  success: number;
  failed: number;
  registeredUuids: string[];
  errors: Array<{ definitionName: string; error: string }>;
}

/**
 * Deletes a registration Fluid has already created, after this droplet failed
 * to record the token that makes it verifiable.
 *
 * Never throws: the caller is already failing, and a rollback failure must not
 * mask the original error. Worst case is a live registration this droplet
 * cannot verify — say so loudly, because the backfill is the recovery path.
 */
async function rollbackRegistration(
  client: FluidClient,
  uuid: string,
): Promise<void> {
  try {
    await client.deleteCallback(uuid);
  } catch (cleanupError) {
    console.error(
      `[Registration] ⚠️ Could not roll back callback ${uuid}; ` +
        "it must be backfilled or deleted manually",
      cleanupError instanceof Error ? cleanupError.message : cleanupError,
    );
  }
}

/**
 * Whether a callback registered at `url` will actually be ANSWERED.
 *
 * Port of `Callback.serves?` (app/models/callback.rb), widened by one case that
 * only exists during the migration.
 *
 * `CallbackSyncService` imports EVERY definition Fluid offers, so the admin
 * list contains names this droplet has no handler for; enabling one registered
 * a URL that 404s on arrival, and Fluid alerted on every dispatch until
 * somebody noticed. That is how TM3's `verify_email_success` registration
 * (Fluid reg 1410) came to exist.
 *
 * Two shapes are accepted, and the second is the migration-only one:
 *
 *  1. one of THIS app's paths on THIS app's host, and
 *  2. one of the RAILS paths on the RAILS host.
 *
 * (2) matters at exactly one moment. Once the droplet-level `droplet.installed`
 * webhook points here but the `callbacks` table rows still hold the Rails urls,
 * a new installation is registered by THIS app from rows describing the OTHER
 * one. Refusing them would register nothing at all: the company would look
 * installed and active while receiving no pricing callbacks, with the only
 * trace a log line on a service nobody is watching yet. Accepting them
 * registers urls Rails is still serving — which is correct, because Rails IS
 * still serving them — and the digest is stored here ready for the repoint.
 *
 * The Rails host is not guessed: it is `Setting.host_server.base_url`, the same
 * value the Rails install job built those urls from.
 *
 * That does mean an actor who can write BOTH the `host_server` setting AND a
 * `callbacks` row could have callbacks delivered to a host of their choosing.
 * It is not an expansion of trust: `Callback.serves?` on the Rails side derives
 * its single permitted host from exactly the same setting, both are behind the
 * Devise-guarded `/admin` tree, and either capability alone is insufficient.
 * Worth knowing if a less-privileged operator role is ever added.
 */
export function servesCallbackUrl(
  url: string,
  hosts: { own?: string; rails?: string } = {},
): boolean {
  let parsed: URL;
  try {
    parsed = new URL(url.trim());
  } catch {
    return false;
  }

  if (parsed.protocol !== "http:" && parsed.protocol !== "https:") return false;
  if (!parsed.host) return false;

  const path = parsed.pathname.replace(/\/$/, "");

  const ours = new Set(Object.values(CALLBACK_ROUTES));
  if (ours.has(path) && (!hosts.own || parsed.hostname === hosts.own)) {
    return true;
  }

  const rails = new Set(Object.values(RAILS_CALLBACK_PATHS));
  if (rails.has(path) && hosts.rails && parsed.hostname === hosts.rails) {
    return true;
  }

  return false;
}

/** The hostname of a configured base url, or undefined if it is unusable. */
function hostOf(value: string | undefined): string | undefined {
  if (!value) return undefined;
  try {
    return new URL(value).hostname;
  } catch {
    return undefined;
  }
}

/** The host Fluid must dispatch to for a callback to reach THIS app. */
export function servedHost(): string | undefined {
  return hostOf(process.env.FLUID_DROPLET_URL);
}

/**
 * The callbacks this droplet registers: every row in the `callbacks` table that
 * an operator has marked active AND whose url is one this app serves.
 *
 * The Rails model refused to activate a row without both a url and a timeout,
 * so both are present by construction — but this filters again rather than
 * trusting it, because rows activated before that validation existed are still
 * in the table and the row could have been written directly.
 */
export async function activeCallbacks({
  // `false` for scripts/cutover.ts ONLY. During a Rails -> Next move these rows
  // still hold the RAILS urls, so the serves-check — which is correct at
  // registration time — would filter every one of them out and the cutover tool
  // would report nothing to move. The tool computes its own destination from
  // the definition name, so it does not need the check.
  enforceServes = true,
}: { enforceServes?: boolean } = {}) {
  const rows = await prisma.callback.findMany({
    where: { active: true },
    orderBy: { name: "asc" },
  });

  const hosts = enforceServes
    ? {
        own: servedHost(),
        rails: hostOf(await hostServerBaseUrl().catch(() => undefined)),
      }
    : {};

  return rows.flatMap((row) => {
    if (!row.name || !row.url || !row.timeoutInSeconds) return [];

    if (enforceServes && !servesCallbackUrl(row.url, hosts)) {
      console.error(
        `[Registration] Refusing to register callback ${row.name}: ` +
          `${JSON.stringify(row.url)} is not a callback URL this droplet serves`,
      );
      return [];
    }

    if (hosts.own && new URL(row.url).hostname !== hosts.own) {
      console.warn(
        `[Registration] ${row.name} is being registered at ${row.url}, which is ` +
          "the RAILS app. That is expected only while the callbacks table has " +
          "not yet been repointed — see CUTOVER.md step 6.",
      );
    }

    return [
      { name: row.name, url: row.url, timeoutInSeconds: row.timeoutInSeconds },
    ];
  });
}

/**
 * Registers every active callback for one installation, storing a digest of
 * each returned verification token.
 *
 * @param dri - the installation's `droplet_installation_uuid`. Required: it is
 *              the only thing that later binds a verified signature to a
 *              tenant, so a blank one would store rows nothing can resolve.
 */
export async function registerCallbacksForCompany(
  client: FluidClient,
  dri: string,
): Promise<CallbackRegistrationResults> {
  const results: CallbackRegistrationResults = {
    success: 0,
    failed: 0,
    registeredUuids: [],
    errors: [],
  };

  if (!dri) {
    console.error(
      "[Registration] Refusing to register callbacks without a droplet_installation_uuid; " +
        "a stored token that cannot be resolved to a tenant is worse than none",
    );
    return results;
  }

  for (const callback of await activeCallbacks()) {
    try {
      console.log(`[Registration] Registering callback: ${callback.name}`);

      const response = await client.createCallback({
        definition_name: callback.name,
        url: callback.url,
        timeout_in_seconds: callback.timeoutInSeconds,
        active: true,
      });

      const registration = response?.callback_registration;

      // Without a uuid there is nothing addressable to roll back — Fluid did
      // not tell us what it created, so bail before claiming success.
      if (!registration?.uuid) {
        throw new Error(
          `Fluid returned no registration uuid for ${callback.name}`,
        );
      }

      // From here a LIVE registration exists. Every failure below has to remove
      // it, or this droplet holds a callback it can never verify.
      if (!registration.verification_token) {
        await rollbackRegistration(client, registration.uuid);
        throw new Error(
          `Fluid returned no verification_token for ${callback.name}; ` +
            "refusing to leave an unverifiable registration in place",
        );
      }

      try {
        await callbackStore.upsert({
          uuid: registration.uuid,
          dri,
          definitionName: registration.definition_name,
          tokenDigest: tokenDigest(registration.verification_token),
          url: registration.url,
        });
      } catch (persistError) {
        await rollbackRegistration(client, registration.uuid);
        throw persistError;
      }

      results.success++;
      results.registeredUuids.push(registration.uuid);
      console.log(`[Registration] ✅ Callback registered: ${callback.name}`);
    } catch (error) {
      results.failed++;
      const message = error instanceof Error ? error.message : String(error);
      results.errors.push({ definitionName: callback.name, error: message });
      console.error(
        `[Registration] ❌ Failed to register callback: ${callback.name}`,
        message,
      );
    }
  }

  return results;
}

/**
 * Deletes the callback registrations created for one installation, and the
 * stored digests that went with them.
 *
 * Port of DropletUninstalledJob#delete_installed_callbacks. The uuids come from
 * `companies.installed_callback_ids`, which is what this droplet created — not
 * from a listing, which is company-scoped and would also return registrations
 * belonging to other droplets installed for the same company.
 */
export async function cleanupCallbacksForCompany(
  client: FluidClient,
  companyId: bigint,
  installedCallbackIds: string[],
  dri: string | null,
): Promise<void> {
  for (const uuid of installedCallbackIds) {
    try {
      await client.deleteCallback(uuid);
    } catch (error) {
      console.error(
        `[Cleanup] Failed to delete callback ${uuid}:`,
        error instanceof Error ? error.message : error,
      );
    }
  }

  // Drop this installation's stored digests.
  //
  // Without this they outlive the registrations deleted above, and a stale row
  // whose dri no longer matches an active company turns a genuine later request
  // into resolvePrincipal -> null -> auth failure, which on a fail-open route
  // is a silent 200.
  if (dri) {
    try {
      await callbackStore.deleteForInstallation(dri);
    } catch (error) {
      console.warn(
        "[Cleanup] Could not clear stored callback tokens; they will be " +
          "overwritten on reinstall but are stale until then",
        error instanceof Error ? error.message : error,
      );
    }
  }

  await prisma.company.update({
    where: { id: companyId },
    data: { installedCallbackIds: [] },
  });
}
