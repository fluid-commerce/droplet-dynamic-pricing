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
import { CALLBACK_ROUTES } from "@/lib/pricing/routes-table";
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
 * Whether this droplet actually answers a callback at `url`.
 *
 * Port of `Callback.serves?` (app/models/callback.rb). `CallbackSyncService`
 * imports EVERY definition Fluid offers, so the admin list contains names this
 * droplet has no handler for; enabling one registered a URL that 404s on
 * arrival, and Fluid alerted on every dispatch until somebody noticed. That is
 * how TM3's `verify_email_success` registration (Fluid reg 1410) came to exist.
 *
 * Three conditions, all of which the Ruby also required:
 *  - absolute http(s) with a host,
 *  - that host is this droplet's own when one is configured, and
 *  - the PATH is one of the routes in CALLBACK_ROUTES.
 *
 * The path is checked rather than the definition name because the two are
 * allowed to differ — that is the whole `subscription_added` ->
 * `cart_subscription_added` problem. Here they no longer do, since the Next
 * paths are named for the definition, but the check stays URL-shaped so a
 * registration left pointing at the RAILS path is refused rather than silently
 * re-registered onto a route this app does not have.
 */
export function servesCallbackUrl(url: string, servedHost?: string): boolean {
  let parsed: URL;
  try {
    parsed = new URL(url.trim());
  } catch {
    return false;
  }

  if (parsed.protocol !== "http:" && parsed.protocol !== "https:") return false;
  if (!parsed.host) return false;
  if (servedHost && parsed.hostname !== servedHost) return false;

  const paths = new Set(Object.values(CALLBACK_ROUTES));
  return paths.has(parsed.pathname.replace(/\/$/, ""));
}

/** The host Fluid must dispatch to for a callback to reach THIS app. */
export function servedHost(): string | undefined {
  const configured = process.env.FLUID_DROPLET_URL;
  if (!configured) return undefined;
  try {
    return new URL(configured).hostname;
  } catch {
    return undefined;
  }
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
  const host = servedHost();

  return rows.flatMap((row) => {
    if (!row.name || !row.url || !row.timeoutInSeconds) return [];

    if (enforceServes && !servesCallbackUrl(row.url, host)) {
      console.error(
        `[Registration] Refusing to register callback ${row.name}: ` +
          `${JSON.stringify(row.url)} is not a callback URL this droplet serves`,
      );
      return [];
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
