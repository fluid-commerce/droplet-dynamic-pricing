/**
 * `isPreferredCustomer` on the `exigo` source, without the nightly sync.
 *
 * The `custom.customer_type` metafield used to be kept honest in BOTH
 * directions by the nightly reconciliation: it promoted new autoships and
 * DEMOTED lost ones. The cart-side writer (`syncPccMetafield`) and the
 * subscription webhooks only promote, or demote on a Fluid pause/cancel. So
 * with the sync gone, a customer whose Exigo autoship lapses without any Fluid
 * subscription event keeps a `preferred_customer` metafield forever — and the
 * read path used to trust that value before ever asking Exigo.
 *
 * The one case where that value is meant to outlive the autoship is
 * `promote_member_type_on_first_subscription` (STU2-3247): there preferred is
 * permanent BY DESIGN, cancelling skips the demote, and the Rails sync skipped
 * `process_lost_autoships` too. So the metafield stays authoritative exactly
 * there, and is not read anywhere else.
 */

import { describe, it, expect } from "vitest";

import { PricingContext } from "./context";
import { cartPayload, exigoStub, recordingDeps } from "@/test/pricing";

const CREDENTIALS = {
  exigo_db_host: "h",
  exigo_db_username: "u",
  exigo_db_password: "p",
  exigo_db_name: "d",
  api_base_url: "https://api",
  api_username: "au",
  api_password: "ap",
};

const PREFERRED_METAFIELD = { value: { customer_type: "preferred_customer" } };

function contextFor(options: {
  metafield?: unknown;
  activeSubscriptions?: boolean;
  exigoAutoship?: boolean;
  permanent?: boolean;
}) {
  const exigo = exigoStub({ autoshipByEmail: options.exigoAutoship ?? false });
  const deps = recordingDeps({
    enabled: true,
    credentials: CREDENTIALS,
    settings: options.permanent
      ? { promote_member_type_on_first_subscription: true }
      : {},
    exigo,
    fluid: {
      metafield: (options.metafield ?? null) as never,
      subscriptions: {
        subscriptions: options.activeSubscriptions ? [{ id: 1 }] : [],
      },
    },
  });
  const ctx = new PricingContext(
    { cart: cartPayload({ customer_id: 42, items: [] }) },
    deps,
  );
  return { ctx, deps, exigo };
}

describe("isPreferredCustomer, exigo source", () => {
  it("does not keep a stale preferred metafield once Exigo says the autoship lapsed", async () => {
    // The finding. Nothing demotes this metafield any more, so trusting it
    // would price this customer as preferred indefinitely.
    const { ctx } = contextFor({
      metafield: PREFERRED_METAFIELD,
      activeSubscriptions: false,
      exigoAutoship: false,
    });

    expect(await ctx.isPreferredCustomer("lapsed@example.com")).toBe(false);
  });

  it("does not read the metafield at all when preferred is not permanent", async () => {
    const { ctx, deps } = contextFor({ metafield: PREFERRED_METAFIELD });

    await ctx.isPreferredCustomer("shopper@example.com");

    expect(deps.callsTo("getMetafieldByKey")).toEqual([]);
  });

  it("still answers preferred from a live Exigo autoship", async () => {
    const { ctx, exigo } = contextFor({ exigoAutoship: true });

    expect(await ctx.isPreferredCustomer("autoship@example.com")).toBe(true);
    expect(exigo.customerHasActiveAutoshipByEmail).toHaveBeenCalled();
  });

  it("keeps the active-subscription override ahead of Exigo (STU2-2531)", async () => {
    const { ctx, exigo } = contextFor({ activeSubscriptions: true });

    expect(await ctx.isPreferredCustomer("subscriber@example.com")).toBe(true);
    expect(exigo.customerHasActiveAutoshipByEmail).not.toHaveBeenCalled();
  });

  it("honours a permanent preferred metafield with no subscription and no autoship", async () => {
    // STU2-3247: preferred-on-first-subscription is permanent on purpose.
    const { ctx, exigo } = contextFor({
      metafield: PREFERRED_METAFIELD,
      permanent: true,
      activeSubscriptions: false,
      exigoAutoship: false,
    });

    expect(await ctx.isPreferredCustomer("promoted@example.com")).toBe(true);
    expect(exigo.customerHasActiveAutoshipByEmail).not.toHaveBeenCalled();
  });

  it("falls through to Exigo when preferred is permanent but the metafield is not set", async () => {
    const { ctx } = contextFor({
      permanent: true,
      metafield: null,
      exigoAutoship: true,
    });

    expect(await ctx.isPreferredCustomer("new@example.com")).toBe(true);
  });
});
