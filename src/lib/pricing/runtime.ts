/**
 * Assembling a live `PricingContext` for one verified callback.
 *
 * This is the only module in src/lib/pricing that touches Prisma, the network
 * or the environment. Everything above it takes `PricingDeps`, so a test drives
 * the whole engine without any of that.
 */

import type { Company } from "@prisma/client";

import { prisma } from "@/lib/db";
import { createFluidClient, PREFERRED_MEMBER_SLUG } from "@/lib/fluid";
import { IntegrationSettings } from "@/lib/integration-settings";
import { ExigoClient, type ExigoReader } from "@/lib/exigo/client";
import { PricingContext } from "./context";
import { preferredLookupCache } from "./cache";
import { pricingFluidApi, type PricingDeps } from "./deps";
import type { CallbackParams } from "./types";

/**
 * Reads the company's integration settings.
 *
 * `findFirst`, not `findUnique`: Rails declared `has_one :integration_setting`
 * but put only a PLAIN index on `integration_settings.company_id`, so more than
 * one row is possible in the database even though the model does not expect it.
 * Ordering by id keeps "which one" stable and matches what `has_one` returns.
 */
export async function loadIntegrationSettings(
  companyId: bigint,
): Promise<IntegrationSettings> {
  const row = await prisma.integrationSetting.findFirst({
    where: { companyId },
    orderBy: { id: "asc" },
  });
  return new IntegrationSettings(row);
}

/**
 * Builds the dependency set for one callback.
 *
 * The Exigo client is constructed only when the company's settings are
 * complete. `null` is what the engine reads as "this company does not run
 * Exigo", which is a definite negative and NOT a failed lookup — the same
 * distinction `exigo_enabled?` made in Ruby.
 */
export async function buildPricingDeps(company: Company): Promise<PricingDeps> {
  const settings = await loadIntegrationSettings(company.id);
  const fluid = pricingFluidApi(createFluidClient(company.authenticationToken));

  const exigo: ExigoReader | null = settings.exigoEnabled
    ? new ExigoClient(settings.exigoCredentials, company.name)
    : null;

  return {
    company: { id: company.id, name: company.name },
    settings,
    fluid,
    exigo,
    cache: preferredLookupCache,
    log: console,
    preferredMemberSlug: PREFERRED_MEMBER_SLUG,

    async recordCartPricingEvent(input) {
      await prisma.cartPricingEvent.create({
        data: {
          companyId: input.companyId,
          // `cart_id` is a Rails `t.integer`, not a bigint. A value that will
          // not fit is dropped rather than allowed to overflow the column.
          cartId: asInt32(input.cartId),
          email: asString(input.email),
          eventType: input.eventType,
          preferredPricingApplied: input.preferredPricingApplied,
          itemsCount: input.itemsCount,
          cartTotal: input.cartTotal.toFixed(2),
          metadata: input.metadata as never,
        },
      });
    },

    reportException(error, context) {
      // Sentry is not wired into the Next app yet; until it is, this is a
      // single greppable line carrying the same fields the Ruby put on the
      // Sentry event. It must never carry the payload — that is where the
      // shopper's email and the company's tokens are.
      console.error(
        `[DynamicPricing] marker=exception ${
          error instanceof Error ? `${error.name}: ${error.message}` : String(error)
        } context=${JSON.stringify(context)}`,
      );
    },
  };
}

export async function buildPricingContext(
  company: Company,
  params: CallbackParams,
): Promise<PricingContext> {
  return new PricingContext(params, await buildPricingDeps(company));
}

function asInt32(value: unknown): number | null {
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) return null;
  const truncated = Math.trunc(parsed);
  if (truncated > 2147483647 || truncated < -2147483648) return null;
  return truncated;
}

function asString(value: unknown): string | null {
  return typeof value === "string" ? value : value == null ? null : String(value);
}
