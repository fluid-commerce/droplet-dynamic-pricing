/**
 * The shared shape of a subscription webhook route.
 *
 * Port of `Webhooks::BaseController`, with the authentication replaced.
 *
 * ## What the Rails version did, and why none of it survives
 *
 * `webhooks/base_controller.rb:19-32` read an `AUTH_TOKEN` header and accepted
 * it if it was `include?`-equal to EITHER the company's
 * `webhook_verification_token` OR `Setting.fluid_webhook.auth_token` — one
 * droplet-wide value, seeded as `"change-me"` and editable in the admin UI. The
 * company itself came from the caller's payload. So a single shared token
 * authenticated a webhook about ANY company, and flipping any customer of any
 * installation between preferred and retail pricing needed nothing else. It was
 * also `include?` rather than a constant-time compare.
 *
 * Here the request must carry a valid HMAC over `{timestamp}.{body}` keyed on
 * THAT company's own `webhook_verification_token`, and the shared token is not
 * a candidate at all — `bootstrapSecret` is deliberately not passed, so these
 * routes have no bootstrap path.
 *
 * ## The honest limit of that
 *
 * Fluid's `Webhook#request_headers` HMACs with the webhook's stored
 * `auth_token` and ALSO echoes that same value in the `AUTH_TOKEN` and
 * `X-Fluid-Token` headers. The signing key therefore travels with every
 * delivery, which makes this an integrity check on the body rather than proof
 * that the caller holds a secret. It is still strictly better than what it
 * replaces — the key is PER TENANT, so one company's token can no longer
 * authenticate a webhook about another — and matching Fluid's scheme is not
 * this repo's choice to make. Recorded here rather than papered over.
 *
 * ## Fails closed
 *
 * No `on*` overrides. A webhook is not the checkout path and a refusal is a
 * retry, which is what a transient failure deserves.
 */

import { withFluidWebhook } from "@fluid-app/droplet-sdk/next";
import { NextResponse } from "next/server";

import { prisma } from "@/lib/db";
import {
  buildSubscriptionWebhookDeps,
  handleSubscriptionWebhook,
  type SubscriptionEvent,
} from "./subscriptions";

export function subscriptionWebhookRoute(event: SubscriptionEvent) {
  const name = `subscription-${event}`;

  return withFluidWebhook(
    {
      name,

      // No bootstrapSecret and no bootstrapEvents. Accepting the shared token
      // for a per-company event is the exact defect this route exists to close.

      async resolve({ dri, fluidShop, companyId, payload }) {
        // `Webhooks::BaseController#find_company` read `payload.company_id` or
        // a TOP-LEVEL `company_id` — neither of which the SDK's hint reader
        // looks at, because it looks for a `company` object. A subscription
        // webhook carries `subscription`, not `company`, so without this the
        // only usable hint would be the X-Fluid-Shop header.
        const fromBody = railsCompanyId(payload);
        const id = companyId ?? fromBody;

        const company = dri
          ? await prisma.company.findFirst({
              where: { dropletInstallationUuid: dri },
            })
          : id !== undefined
            ? await prisma.company.findFirst({
                where: { fluidCompanyId: BigInt(id) },
              })
            : fluidShop
              ? await prisma.company.findFirst({ where: { fluidShop } })
              : null;

        // A blank token can never be an HMAC key, and the wrapper refuses when
        // no candidate is offered. That is the correct outcome: an installation
        // with no verification token cannot be verified.
        if (!company?.webhookVerificationToken) return null;

        return {
          secret: company.webhookVerificationToken,
          principal: company,
        };
      },
    },

    async ({ payload, principal: company }) => {
      // Never null on a non-bootstrap event: the wrapper offers no candidate
      // secret without a resolved company, and refuses before reaching here.
      if (!company) {
        return NextResponse.json({ error: "unauthorized" }, { status: 401 });
      }

      const deps = await buildSubscriptionWebhookDeps(company);
      const result = await handleSubscriptionWebhook(event, payload, deps);

      // Rails rendered 200 on success and 400 on failure
      // (webhooks/subscription_*_controller.rb). Kept: a non-2xx is a retry
      // signal to Fluid, which is what "customer id not found" and a transient
      // Fluid failure both deserve.
      return NextResponse.json(result, { status: result.success ? 200 : 400 });
    },
  );
}

/**
 * The company id in the two places the Rails controller looked for it.
 *
 * Deliberately NOT merged into the SDK's hint reader: this is a shape specific
 * to this droplet's subscription webhooks, and the SDK's rule is shared across
 * the fleet.
 */
function railsCompanyId(payload: unknown): string | number | undefined {
  if (!payload || typeof payload !== "object") return undefined;
  const record = payload as Record<string, unknown>;
  const nested = record["payload"];
  const inner =
    nested && typeof nested === "object"
      ? (nested as Record<string, unknown>)
      : {};

  const value = inner["company_id"] ?? record["company_id"];
  return typeof value === "string" || typeof value === "number"
    ? value
    : undefined;
}
