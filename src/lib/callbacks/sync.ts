/**
 * Callback definition sync.
 *
 * Port of app/services/callback_sync_service.rb. Pulls the catalogue of
 * callback definitions Fluid publishes at GET /api/callback/definitions and
 * mirrors it into the local `callbacks` table so the admin UI can list them
 * and attach a url + timeout to the ones this droplet implements.
 *
 * A definition name is the exact `name:` from one of the YAML files in fluid at
 * app/lib/callback_definitions/*.yml — "cart_item_added", "update_cart_tax".
 * A route directory name is not a definition name, and inventing one produces a
 * registration Fluid will never call.
 */

import { createFluidClient } from "@/lib/fluid";
import { prisma } from "@/lib/db";
import { fluidApiSettings } from "@/lib/settings";

export interface CallbackSyncResult {
  success: boolean;
  message: string;
}

export async function syncCallbackDefinitions(): Promise<CallbackSyncResult> {
  try {
    const { api_key, base_url } = await fluidApiSettings();
    const client = createFluidClient(api_key, base_url);

    const response = await client.listCallbackDefinitions();
    const definitions = response?.definitions ?? [];

    if (definitions.length === 0) {
      return { success: false, message: "No callback definitions found" };
    }

    for (const definition of definitions) {
      if (!definition?.name) continue;
      try {
        // find-then-write rather than upsert: Rails put NO unique index on
        // callbacks.name (uniqueness was a model validation only), and the
        // schema keeps that faithfully, so there is no unique key to upsert on.
        const existing = await prisma.callback.findFirst({
          where: { name: definition.name },
        });

        if (existing) {
          // Rails assigned description and `active: false` on every sync. The
          // description is kept; forcing active back to false is NOT — it would
          // silently switch off a callback an operator had enabled, and on a
          // fail-open route the symptom is silence. New rows still start
          // inactive, which is where that rule actually mattered.
          await prisma.callback.update({
            where: { id: existing.id },
            data: { description: definition.description ?? null },
          });
        } else {
          await prisma.callback.create({
            data: {
              name: definition.name,
              description: definition.description ?? null,
              active: false,
            },
          });
        }
      } catch (error) {
        console.error(
          `[CallbackSync] Failed to sync callback ${definition.name}:`,
          error instanceof Error ? error.message : error,
        );
      }
    }

    return {
      success: true,
      message: `Successfully synced ${definitions.length} callbacks`,
    };
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    console.error("[CallbackSync] Callback sync failed:", message);
    return { success: false, message: `Sync failed: ${message}` };
  }
}
