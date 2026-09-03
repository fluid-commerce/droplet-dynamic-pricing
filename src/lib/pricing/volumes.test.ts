/**
 * Volume adjustment (STU2-2526, and the `subscription_volume_source` split from
 * STU2-2531 / Oliabo).
 *
 * Volumes are CV/QV — commission. Getting them wrong does not show up in a
 * cart total, it shows up in what a rep is paid, which is why the "write retail
 * and log" fallback exists rather than a silent ratio calculation.
 */

import { describe, it, expect } from "vitest";

import {
  cartItemVolumes,
  scaledUnitVolume,
  subscriptionValueRatio,
  PricingContext,
} from "./context";
import { cartPayload, recordingDeps } from "@/test/pricing";
import type { Json, VariantBaseVolumes } from "./types";

const base = (overrides: Partial<VariantBaseVolumes> = {}): VariantBaseVolumes => ({
  cv: 100,
  qv: 100,
  pcCv: 60,
  pcQv: 60,
  price: "100.0",
  subscriptionPrice: "80.0",
  ...overrides,
});

const silent = { info: () => {}, warn: () => {}, error: () => {} };

describe("subscriptionValueRatio", () => {
  it("is subscription_price / price", () => {
    expect(subscriptionValueRatio(base())).toBeCloseTo(0.8);
  });

  it("falls back to 1.0 (no reduction) when either price is missing or non-positive", () => {
    expect(subscriptionValueRatio(base({ price: "0" }))).toBe(1);
    expect(subscriptionValueRatio(base({ subscriptionPrice: null }))).toBe(1);
    expect(subscriptionValueRatio(base({ subscriptionPrice: "-5" }))).toBe(1);
  });

  it("clamps above 1, so a subscription priced higher than retail never inflates volume", () => {
    expect(subscriptionValueRatio(base({ subscriptionPrice: "200.0" }))).toBe(1);
  });
});

describe("scaledUnitVolume", () => {
  it("rounds on the LINE TOTAL and divides back per unit, matching Fluid core", () => {
    // 33 * 3 * 0.8 = 79.2 -> 79 on the line -> 26 per unit. Rounding per unit
    // first would give 26 * 3 = 78, which is a different line total.
    expect(scaledUnitVolume(33, 0.8, 3)).toBe(26);
  });

  it("treats a missing or zero quantity as 1", () => {
    expect(scaledUnitVolume(10, 1, 0)).toBe(10);
    expect(scaledUnitVolume(10, 1, undefined)).toBe(10);
  });

  it("never goes negative", () => {
    expect(scaledUnitVolume(-5, 1, 1)).toBe(0);
  });
});

describe("cartItemVolumes", () => {
  it("scales retail volumes by the discount under the default price_ratio source", () => {
    expect(cartItemVolumes(base(), "subscription", 1, "price_ratio", silent, "c")).toEqual(
      { cv: 80, qv: 80 },
    );
  });

  it("restores the retail base volumes in regular mode", () => {
    expect(cartItemVolumes(base(), "regular", 1, "price_ratio", silent, "c")).toEqual({
      cv: 100,
      qv: 100,
    });
  });

  it("writes pc_cv/pc_qv directly under the preferred_customer source, with NO ratio", () => {
    expect(
      cartItemVolumes(base(), "subscription", 1, "preferred_customer", silent, "c"),
    ).toEqual({ cv: 60, qv: 60 });
  });

  it("falls back to RETAIL volumes, not the ratio, when pc_cv/pc_qv are missing", () => {
    // Deliberate: a catalog misconfiguration should surface as plainly
    // unadjusted volumes rather than silently masquerading as a valid ratio
    // calculation.
    const warnings: string[] = [];
    const log = { ...silent, warn: (m: string) => warnings.push(m) };

    expect(
      cartItemVolumes(
        base({ pcCv: null, pcQv: null }),
        "subscription",
        1,
        "preferred_customer",
        log,
        "crt_1",
      ),
    ).toEqual({ cv: 100, qv: 100 });
    expect(warnings.join("\n")).toContain("missing pc_cv/pc_qv");
  });

  it("ignores the preferred_customer source in regular mode", () => {
    expect(
      cartItemVolumes(base(), "regular", 1, "preferred_customer", silent, "c"),
    ).toEqual({ cv: 100, qv: 100 });
  });
});

describe("updateCartItemsVolumes", () => {
  const item = (overrides: Json = {}): Json => ({
    id: 1,
    variant_id: "v1",
    quantity: 1,
    ...overrides,
  });

  const variantRows = [
    {
      country_code: "US",
      cv: 100,
      qv: 100,
      pc_cv: 60,
      pc_qv: 60,
      price: "100.0",
      subscription_price: "80.0",
    },
  ];

  it("is a complete no-op unless the company opted in", async () => {
    // Off by default: the droplet is shared, and some companies manage volumes
    // through other droplets entirely.
    const deps = recordingDeps({ fluid: { variants: { v1: variantRows } } });
    const ctx = new PricingContext({ cart: cartPayload() }, deps);

    await ctx.updateCartItemsVolumes([item()], "subscription");
    expect(deps.calls).toHaveLength(0);
  });

  it("writes volumes when the company opted in", async () => {
    const deps = recordingDeps({
      settings: { adjust_volumes_for_subscription: true },
      fluid: { variants: { v1: variantRows } },
    });
    const ctx = new PricingContext({ cart: cartPayload() }, deps);

    await ctx.updateCartItemsVolumes([item()], "subscription");

    expect(deps.callsTo("updateCartItemVolumes")[0].args.slice(1)).toEqual([
      1,
      { cv: 80, qv: 80 },
    ]);
  });

  it("SKIPS an item whose variant cannot be resolved rather than zeroing it", async () => {
    // Zeroing here would wipe real commission values on Fluid.
    const deps = recordingDeps({
      settings: { adjust_volumes_for_subscription: true },
      fluid: { variantErrors: ["v1"] },
    });
    const ctx = new PricingContext({ cart: cartPayload() }, deps);

    await ctx.updateCartItemsVolumes([item()], "subscription");
    expect(deps.callsTo("updateCartItemVolumes")).toHaveLength(0);
  });

  it("keeps going after one item fails, so a batch is not stranded", async () => {
    const deps = recordingDeps({
      settings: { adjust_volumes_for_subscription: true },
      fluid: { variants: { v1: variantRows, v2: variantRows } },
    });
    const original = deps.fluid.updateCartItemVolumes;
    let seen = 0;
    deps.fluid.updateCartItemVolumes = async (token, itemId, volumes) => {
      seen += 1;
      if (seen === 1) throw new Error("transient");
      return original(token, itemId, volumes);
    };

    const ctx = new PricingContext({ cart: cartPayload() }, deps);
    await ctx.updateCartItemsVolumes(
      [item({ id: 1, variant_id: "v1" }), item({ id: 2, variant_id: "v2" })],
      "subscription",
    );

    // The second item still got its volumes, and the first failure was
    // reported on its own.
    expect(deps.callsTo("updateCartItemVolumes")).toHaveLength(1);
    expect(deps.reported).toHaveLength(1);
  });

  it("resolves volumes against the SHIP country, unlike prices", async () => {
    // cartCountry falls back to ship_to; cartPricingCountry deliberately does
    // not (STU2-3108). Volumes are the one thing allowed the wider country.
    const deps = recordingDeps({
      settings: { adjust_volumes_for_subscription: true },
      fluid: {
        variants: {
          v1: [
            { country_code: "AU", cv: 50, qv: 50, price: "100.0", subscription_price: "100.0" },
            { country_code: "US", cv: 100, qv: 100, price: "100.0", subscription_price: "100.0" },
          ],
        },
      },
    });
    const ctx = new PricingContext(
      {
        cart: cartPayload({
          country_code: null,
          country: null,
          ship_to: { country_code: "AU" },
        }),
      },
      deps,
    );

    await ctx.updateCartItemsVolumes([item()], "subscription");
    expect(deps.callsTo("updateCartItemVolumes")[0].args[2]).toEqual({
      cv: 50,
      qv: 50,
    });
  });
});
