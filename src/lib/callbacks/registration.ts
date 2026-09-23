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
import { dropletConfig, filterEnabled } from "@/lib/config";
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

/** One callback, resolved to the URL it is registered at. */
export interface ActiveCallback {
  name: string;
  url: string;
  timeoutInSeconds: number;
}

/**
 * The callbacks this droplet registers, from `droplet.config.ts`.
 *
 * This used to read the `callbacks` table and filter it through a port of
 * `Callback.serves?` — a guard against registering a URL this app has no route
 * for, which was necessary because the table was populated by syncing EVERY
 * definition Fluid offers and then edited by hand. Both the table and the guard
 * are gone: a URL is now built from CALLBACK_ROUTES rather than typed, so
 * "serves it" holds by construction, and the only way to get it wrong is to
 * name a definition the table has no entry for — which is checked here and
 * refused, rather than registered and left to 404 on every dispatch.
 *
 * `FLUID_DROPLET_URL` is the host, the same env var the webhook registration
 * uses. Unset, this registers nothing at all and says so: a registration built
 * on a missing base would point at a path with no origin, and Fluid would
 * accept it and then never reach it.
 */
export function activeCallbacks(): ActiveCallback[] {
  const base = (process.env.FLUID_DROPLET_URL ?? "").trim().replace(/\/$/, "");

  if (!base) {
    console.error(
      "[Registration] FLUID_DROPLET_URL is not set; refusing to register any " +
        "callback. Fluid would accept a registration with no host and then " +
        "never deliver to it, and nothing on this side would error.",
    );
    return [];
  }

  return filterEnabled(dropletConfig.callbacks).flatMap((callback) => {
    const path = CALLBACK_ROUTES[callback.definition_name];

    if (!path) {
      console.error(
        `[Registration] Refusing to register ${callback.definition_name}: ` +
          "it is not in CALLBACK_ROUTES, so this droplet serves no route for " +
          "it. Add the route and its entry in the table, or remove it from " +
          "droplet.config.ts.",
      );
      return [];
    }

    return [
      {
        name: callback.definition_name,
        url: `${base}${path}`,
        timeoutInSeconds: callback.timeoutInSeconds,
      },
    ];
  });
}

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

  for (const callback of activeCallbacks()) {
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
