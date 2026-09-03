/**
 * STU2-3108 — the cross-country price guard.
 *
 * The incident: a Philippine cart was charged 113.85 instead of 2,499, because
 * the droplet echoed back a price Fluid had resolved against ANOTHER country,
 * and Fluid then wrote that as an admin override and LOCKED the line, so the
 * right price could never come back on its own.
 *
 * The guard has to hold in five directions at once, and four of them are ways
 * an over-eager version of it breaks something else:
 *
 *  - refuse a price that demonstrably belongs to another country (the bug), but
 *  - accept it when the cart's OWN row also carries that number (Oliabo cart
 *    757644: a US cart handed its own `wholesale` was called foreign because AU
 *    happened to share the figure, and a correct write was dropped),
 *  - never read variant_country for a BUNDLE,
 *  - forward unchecked when the pricing country cannot be resolved (a guest
 *    cart with no address yet), and
 *  - forward unchecked when the variant lookup itself failed.
 */

import { describe, it, expect } from "vitest";

import { PricingContext } from "./context";
import { cartPayload, recordingDeps } from "@/test/pricing";
import type { Json } from "./types";

const row = (overrides: Json): Json => ({
  country_code: "US",
  currency_code: "USD",
  active: true,
  price: "100.0",
  subscription_price: "90.0",
  wholesale: null,
  wholesale_subscription_price: null,
  cv: 10,
  qv: 10,
  ...overrides,
});

const item = (overrides: Json = {}): Json => ({
  id: 1,
  variant_id: "v1",
  quantity: 1,
  metadata: {},
  ...overrides,
});

function context(variants: Record<string, Json[]>, cart: Partial<Json> = {}) {
  const deps = recordingDeps({ fluid: { variants } });
  const ctx = new PricingContext({ cart: cartPayload(cart) }, deps);
  return { ctx, deps };
}

describe("countrySafePrice", () => {
  it("refuses a price that belongs to another country and alerts", async () => {
    // The PH cart, exactly: the payload carries the CAD figure, and the cart's
    // own PH row prices at 2499.
    const { ctx, deps } = context(
      {
        v1: [
          row({ country_code: "PH", currency_code: "PHP", price: "2499.0" }),
          row({ country_code: "CA", currency_code: "CAD", price: "113.85" }),
        ],
      },
      { country_code: "PH" },
    );

    const price = await ctx.countrySafePrice(item(), "113.85", "regular");

    // The cart's own row has a positive price, so the AUTHORITATIVE figure is
    // used rather than the item being dropped.
    expect(price).toBe(2499);
    expect(deps.reported).toHaveLength(0);
  });

  it("drops the item and alerts when the cart's own row has no price to substitute", async () => {
    const { ctx, deps } = context(
      {
        v1: [
          // Sold in PH, but the price is missing — a real misconfiguration.
          row({ country_code: "PH", currency_code: "PHP", price: "0.0" }),
          row({ country_code: "CA", currency_code: "CAD", price: "113.85" }),
        ],
      },
      { country_code: "PH" },
    );

    const price = await ctx.countrySafePrice(item(), "113.85", "regular");

    expect(price).toBeNull();
    expect(deps.reported).toHaveLength(1);
    expect((deps.reported[0].error as Error).name).toBe("CrossCountryPriceError");
    expect(deps.reported[0].context).toMatchObject({
      cart_country: "PH",
      foreign_country: "CA",
    });
  });

  it("drops the item WITHOUT alerting when the variant is not sold in the cart's country", async () => {
    // Fluid creates a row per company country, so one the variant is not sold
    // in still exists — inactive, at 0.00. Fluid blocks the line at checkout;
    // there is nothing for an operator to action.
    const { ctx, deps } = context(
      {
        v1: [
          row({
            country_code: "PH",
            currency_code: "PHP",
            price: "0.0",
            active: false,
          }),
          row({ country_code: "CA", currency_code: "CAD", price: "113.85" }),
        ],
      },
      { country_code: "PH" },
    );

    expect(await ctx.countrySafePrice(item(), "113.85", "regular")).toBeNull();
    expect(deps.reported).toHaveLength(0);
    expect(deps.logs.info.join("\n")).toContain("not sold in PH");
  });

  it("accepts the payload when the cart's OWN row also carries that figure", async () => {
    // Oliabo cart 757644. The US cart was handed its own `wholesale` price;
    // AU happened to list the same number, and a "does any foreign row match?"
    // check alone dropped a correct write.
    const { ctx, deps } = context(
      {
        v1: [
          row({ country_code: "US", price: "100.0", wholesale: "70.0" }),
          row({ country_code: "AU", currency_code: "AUD", price: "70.0" }),
        ],
      },
      { country_code: "US" },
    );

    expect(await ctx.countrySafePrice(item(), "70.0", "regular")).toBe(70);
    expect(deps.reported).toHaveLength(0);
  });

  it("never reads variant_country for a bundle", async () => {
    // A bundle's master variant may carry priced rows while its lines price at
    // 0.0, so reading the row would overwrite Fluid's bundle total and lock it.
    const { ctx, deps } = context(
      { v1: [row({ country_code: "CA", currency_code: "CAD", price: "113.85" })] },
      { country_code: "PH" },
    );

    const price = await ctx.countrySafePrice(
      item({ metadata: { is_bundle: true } }),
      "113.85",
      "regular",
    );

    expect(price).toBe(113.85);
    expect(deps.callsTo("getVariant")).toHaveLength(0);
  });

  it("forwards the payload price unchecked when the pricing country is unresolvable", async () => {
    // A guest cart with no address yet. Refusing here would be the safer end
    // state but would also stop repricing every guest cart.
    const { ctx, deps } = context(
      { v1: [row({ country_code: "CA", price: "113.85" })] },
      { country_code: null, country: null },
    );

    expect(await ctx.countrySafePrice(item(), "113.85", "regular")).toBe(113.85);
    expect(deps.callsTo("getVariant")).toHaveLength(0);
    expect(deps.logs.warn.join("\n")).toContain(
      "Cannot resolve the pricing country",
    );
  });

  it("forwards the payload price unchecked when the variant lookup fails", async () => {
    const deps = recordingDeps({ fluid: { variantErrors: ["v1"] } });
    const ctx = new PricingContext(
      { cart: cartPayload({ country_code: "PH" }) },
      deps,
    );

    expect(await ctx.countrySafePrice(item(), "113.85", "regular")).toBe(113.85);
    expect(deps.logs.error.join("\n")).toContain("Failed to fetch variant v1");
  });

  it("reads the subscription column for a subscription price and the base column otherwise", async () => {
    const variants = {
      v1: [
        row({ country_code: "PH", price: "2499.0", subscription_price: "1999.0" }),
        row({ country_code: "CA", currency_code: "CAD", price: "113.85" }),
      ],
    };

    const a = context(variants, { country_code: "PH" });
    expect(
      await a.ctx.countrySafePrice(item(), "113.85", "subscription"),
    ).toBe(1999);

    const b = context(variants, { country_code: "PH" });
    expect(await b.ctx.countrySafePrice(item(), "113.85", "regular")).toBe(2499);
  });

  it("memoizes the variant lookup across items sharing a variant", async () => {
    const { ctx, deps } = context(
      { v1: [row({ country_code: "US" })] },
      { country_code: "US" },
    );

    await ctx.countrySafePrice(item({ id: 1 }), "100.0", "regular");
    await ctx.countrySafePrice(item({ id: 2 }), "100.0", "regular");

    // Eight of these callbacks block the shopper's request inside a 20s
    // ceiling; an N-line cart must not be N variant round trips.
    expect(deps.callsTo("getVariant")).toHaveLength(1);
  });

  it("resolves the pricing country from cart.country.iso when country_code is absent", async () => {
    const { ctx } = context(
      { v1: [row({ country_code: "US", price: "100.0" })] },
      { country_code: null, country: { iso: "US" } },
    );

    expect(ctx.cartPricingCountry).toBe("US");
  });

  it("never takes the pricing country from ship_to, only the volume country does", async () => {
    // Taking a PRICE from ship_to while the currency comes from the cart IS the
    // STU2-3108 bug. `cartCountry` is for volume resolution only.
    const { ctx } = context(
      {},
      { country_code: null, country: null, ship_to: { country_code: "CA" } },
    );

    expect(ctx.cartPricingCountry).toBeUndefined();
    expect(ctx.cartCountry).toBe("CA");
  });

  it('treats an EMPTY country_code as unresolvable, not as absent (Ruby `||`)', async () => {
    // `"" || cart.country.iso` is `""` in Ruby, and `"".blank?` is true — so
    // the payload price is forwarded unchecked. Falling through to
    // `country.iso` instead would run the cross-country guard against a country
    // the payload never claimed, and could substitute or refuse a price where
    // Rails forwarded it.
    const { ctx, deps } = context(
      { v1: [row({ country_code: "CA", currency_code: "CAD", price: "113.85" })] },
      { country_code: "", country: { iso: "PH" } },
    );

    expect(ctx.cartPricingCountry).toBe("");
    expect(await ctx.countrySafePrice(item(), "113.85", "regular")).toBe(113.85);
    expect(deps.callsTo("getVariant")).toHaveLength(0);
  });
});
