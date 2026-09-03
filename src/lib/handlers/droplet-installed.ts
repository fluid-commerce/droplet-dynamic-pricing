/**
 * Droplet Installation Handler
 *
 * Port of app/jobs/droplet_installed_job.rb.
 *
 * Fluid sends the company's credentials in this payload and nowhere else, so
 * this is where a `companies` row is created or refreshed. It then registers
 * the callbacks an operator has marked active, capturing each verification
 * token as a digest.
 */

import { z } from "zod";

import { prisma } from "@/lib/db";
import { createFluidClient } from "@/lib/fluid";
import { dropletConfig, registerAllFeatures } from "@/lib/config";
import { registerCallbacksForCompany } from "@/lib/callbacks";
import { dropletSettings } from "@/lib/settings";

/**
 * Fluid nests the company under `company` and names the droplet's own uuid
 * `droplet_uuid` there — which Rails then stored in `company_droplet_uuid`.
 *
 * Permissive on purpose: Fluid adds fields to this payload over time, and a
 * strict schema would turn a new field into a failed install.
 */
const installCompanySchema = z.object({
  fluid_shop: z.string(),
  name: z.string(),
  fluid_company_id: z.union([z.number(), z.string()]),
  droplet_uuid: z.string(),
  droplet_installation_uuid: z.string().optional(),
  authentication_token: z.string(),
  webhook_verification_token: z.string().optional(),
});

const installPayloadSchema = z.object({ company: installCompanySchema });

export async function handleDropletInstalled(payload: unknown): Promise<void> {
  const { company: data } = installPayloadSchema.parse(payload);

  // Guard against cross-contamination. Fluid delivers install webhooks per
  // droplet, but several droplets can share a webhook endpoint during
  // development, and a droplet that adopts another droplet's installation would
  // register callbacks against the wrong tenant.
  //
  // Rails did this in the controller (validate_droplet_authorization) and
  // rejected with a 401. Doing it here instead means the check still applies
  // when the event arrives by any other route.
  const expected = (await dropletSettings()).uuid ?? process.env.DROPLET_UUID;
  if (expected && data.droplet_uuid !== expected) {
    console.log(
      `[DropletInstalled] Ignoring — droplet_uuid ${data.droplet_uuid} is not ours (${expected})`,
    );
    return;
  }
  if (!expected) {
    console.warn(
      "[DropletInstalled] No droplet uuid configured — cannot verify this event is for this droplet",
    );
  }

  const fluidCompanyId = BigInt(data.fluid_company_id);

  // Rails matched on fluid_shop. Kept, because that is what decides whether an
  // existing production row is updated or duplicated, and `fluid_shop` has only
  // a plain index — findFirst, not findUnique.
  const existing = await prisma.company.findFirst({
    where: { fluidShop: data.fluid_shop },
  });

  const attributes = {
    fluidShop: data.fluid_shop,
    name: data.name,
    fluidCompanyId,
    authenticationToken: data.authentication_token,
    webhookVerificationToken: data.webhook_verification_token ?? null,
    dropletInstallationUuid: data.droplet_installation_uuid ?? null,
    companyDropletUuid: data.droplet_uuid,
    active: true,
    // A reinstall arrives as a fresh `droplet.installed`. Clearing this is what
    // makes the row live again; leaving it set would keep the company excluded
    // from every `uninstalledAt: null` lookup, including tenant resolution.
    uninstalledAt: null,
  };

  const company = existing
    ? await prisma.company.update({
        where: { id: existing.id },
        data: attributes,
      })
    : await prisma.company.create({ data: attributes });

  console.log(
    `[DropletInstalled] Company ${company.id} (${company.name}) installed`,
  );

  const client = createFluidClient(company.authenticationToken);

  // Per-company webhooks from droplet.config.ts — the five subscription events.
  // Failures are logged, not fatal; Rails did not fail an install over them
  // either.
  //
  // ## Why the COMPANY's token and not the shared one
  //
  // The template registers these with `FLUID_WEBHOOK_AUTH_TOKEN`, on the
  // reasoning that Fluid echoes `auth_token` back as a plaintext header and the
  // verification token should not travel that way. That reasoning does not
  // survive contact with `Webhook#request_headers` (fluid app/models/webhook.rb
  // :169-189): the value it HMACs with IS the webhook's stored `auth_token`,
  // and it puts that same value in the `AUTH_TOKEN` and `X-Fluid-Token`
  // headers. There is no separate signing secret.
  //
  // So registering with the shared token would mean every company's
  // subscription webhooks verify against ONE droplet-wide value — the fleet
  // pattern this migration exists to remove — and Fluid would broadcast that
  // shared value in a header on every delivery to every tenant. Registering
  // with the company's own token keeps the key per tenant, which is also what
  // Rails did (`droplet_installed_job.rb#build_webhook_attributes`).
  //
  // The residual weakness — the key travels in a header — is Fluid's scheme,
  // not this droplet's choice. See src/lib/webhooks/route.ts.
  try {
    await registerAllFeatures(
      client,
      dropletConfig,
      company.webhookVerificationToken ??
        process.env.FLUID_WEBHOOK_AUTH_TOKEN ??
        "",
    );
  } catch (error) {
    console.error(
      `[DropletInstalled] Feature registration failed for company ${company.id}:`,
      error instanceof Error ? error.message : error,
    );
  }

  const dri = company.dropletInstallationUuid ?? "";

  // Register FIRST, prune afterwards, and only when the registration actually
  // succeeded.
  //
  // This used to clear the stored digests before registering. Webhook delivery
  // is at-least-once, so a redelivered `droplet.installed` for an installation
  // that is already working would: delete the live digest, then get 409 from
  // `createCallback` because Fluid still holds that registration, then log the
  // failure and return 202. Fluid keeps calling the original registration with
  // the original token, and the droplet — now holding no digest for it —
  // refuses every one of those callbacks behind a neutral 200. A retry of a
  // successful install silently broke it.
  //
  // So local state is never destroyed before a replacement exists.
  const results = await registerCallbacksForCompany(client, dri);

  if (dri) {
    if (results.failed === 0 && results.registeredUuids.length > 0) {
      // A clean run: every enabled definition was created and its fresh token
      // stored. Anything else still on this installation is from a previous
      // registration Fluid no longer routes to, so it can go.
      await prisma.fluidCallbackRegistration
        .deleteMany({
          where: { dri, uuid: { notIn: results.registeredUuids } },
        })
        .catch((error: unknown) => {
          console.warn(
            "[DropletInstalled] Could not prune superseded callback tokens:",
            error instanceof Error ? error.message : error,
          );
        });
    } else if (results.failed > 0) {
      // Deliberately keeps every stored row. On a redelivery the failure is
      // typically a 409 for a registration that is live and working, and whose
      // token we already hold — deleting that row is precisely how a healthy
      // installation gets broken.
      console.warn(
        `[DropletInstalled] Keeping existing callback tokens for ${dri}: ` +
          "registration did not complete cleanly, so stored digests may still " +
          "be the only copy of a live registration's token.",
      );
    }
  }

  if (results.registeredUuids.length > 0) {
    // MERGED, not replaced. Delivery is at-least-once and registration is
    // per-callback, so a retry after a partial success registers only what
    // failed the first time — replacing the list would drop the uuid of the
    // callback that succeeded on the earlier attempt. Uninstall cleanup reads
    // this list, so that callback would then be left live at Fluid while its
    // digest is deleted and its company deactivated: every one of its calls
    // refused behind a 200, with nothing pointing at the cause.
    const existing = Array.isArray(company.installedCallbackIds)
      ? (company.installedCallbackIds as unknown[]).filter(
          (id): id is string => typeof id === "string",
        )
      : [];
    const merged = Array.from(
      new Set([...existing, ...results.registeredUuids]),
    );
    await prisma.company.update({
      where: { id: company.id },
      data: { installedCallbackIds: merged },
    });
  }

  if (results.failed > 0) {
    console.warn(
      `[DropletInstalled] ${results.failed} callback(s) failed to register for company ${company.id}. ` +
        "Those callbacks will be refused until they are re-registered or backfilled.",
    );
  }
}
