/**
 * The nine services, asserted on the SEQUENCE of Fluid calls they emit.
 *
 * The response body is the wrong thing to test here: Fluid discards it for
 * eight of the nine. What a shopper experiences is the writes — which lines
 * were repriced, to what, and whether the cart was stamped.
 */

import { describe, it, expect } from "vitest";

import { PricingContext } from "./context";
import {
  cartCountryChanged,
  cartCustomerAttached,
  cartEmailOnCreate,
  cartItemAdded,
  cartItemUpdated,
  subscriptionAdded,
  subscriptionRemoved,
} from "./services";
import { cartPayload, exigoStub, recordingDeps } from "@/test/pricing";
import type { Json } from "./types";

const line = (id: number, overrides: Json = {}): Json => ({
  id,
  variant_id: null,
  quantity: 1,
  price: "20.0",
  subscription_price: "16.0",
  product: { price: "20.0" },
  metadata: {},
  ...overrides,
});

const CREDENTIALS = {
  exigo_db_host: "h",
  exigo_db_username: "u",
  exigo_db_password: "p",
  exigo_db_name: "d",
  api_base_url: "https://api",
  api_username: "au",
  api_password: "ap",
};

describe("cart_item_added", () => {
  it("reprices, stamps the cart AND affirms the slug in the response", async () => {
    // The two channels are not atomic: the price goes to the cart items while
    // the slug lives in cart metadata and in the response. Writing only one is
    // how an order kept a subscription price with a retail price_type.
    const deps = recordingDeps();
    const ctx = new PricingContext(
      {
        cart: cartPayload({
          metadata: { price_type: "preferred_customer" },
          items: [line(1)],
        }),
        cart_item: line(1),
      },
      deps,
    );

    const result = await cartItemAdded(ctx);

    expect(deps.calls.map((c) => c.method)).toEqual([
      "updateCartItemsPrices",
      "appendCartMetadata",
    ]);
    expect(deps.callsTo("updateCartItemsPrices")[0].args[1]).toEqual([
      { id: 1, price: 16 },
    ]);
    expect(deps.callsTo("appendCartMetadata")[0].args[1]).toEqual({
      price_type: "preferred_customer",
    });
    expect(result).toEqual({
      success: true,
      metadata: { price_type: "preferred_customer" },
      message: "Cart item updated to subscription price successfully",
    });
  });

  it("re-derives preferred status when the stamp is missing (STU2-2531)", async () => {
    // The cart was emptied after the attach that stamped it, and attach does
    // not re-fire on a re-add. A cart carrying a subscription line qualifies on
    // its own, for free.
    const deps = recordingDeps();
    const ctx = new PricingContext(
      {
        cart: cartPayload({
          metadata: {},
          items: [line(1, { subscription: true })],
        }),
        cart_item: line(1, { subscription: true }),
      },
      deps,
    );

    await cartItemAdded(ctx);
    expect(deps.callsTo("updateCartItemsPrices")).toHaveLength(1);
    // The in-cart check is free, so no external lookup was spent.
    expect(deps.callsTo("listSubscriptionsByCustomer")).toHaveLength(0);
  });

  it("does nothing for a cart that qualifies for nothing", async () => {
    const deps = recordingDeps();
    const ctx = new PricingContext(
      { cart: cartPayload({ metadata: {}, items: [line(1)] }), cart_item: line(1) },
      deps,
    );

    await expect(cartItemAdded(ctx)).resolves.toEqual({
      success: true,
      message: "Cart does not have preferred_customer pricing",
    });
    expect(deps.calls).toHaveLength(0);
  });

  it("reprices EVERY item of a batched callback in one PATCH", async () => {
    // Fluid's BATCH_CART_ITEM_CALLBACKS flag sends one cart_item_added per add
    // operation with the added items in `cart_items`.
    const deps = recordingDeps();
    const ctx = new PricingContext(
      {
        cart: cartPayload({
          metadata: { price_type: "preferred_customer" },
          items: [line(1), line(2)],
        }),
        cart_item: line(1),
        cart_items: [line(1), line(2)],
      },
      deps,
    );

    await cartItemAdded(ctx);

    expect(deps.callsTo("updateCartItemsPrices")).toHaveLength(1);
    expect(deps.callsTo("updateCartItemsPrices")[0].args[1]).toEqual([
      { id: 1, price: 16 },
      { id: 2, price: 16 },
    ]);
  });

  it("prefers Fluid's bundle figure over a zero subscription_price", async () => {
    // A bundle's "0.0" is a truthy String in Ruby, so a plain `||` on the raw
    // field would stop there and write zero — which Fluid then locks.
    const deps = recordingDeps();
    const bundle = line(1, {
      subscription_price: "0.0",
      metadata: { bundle_group_base_price: "45.0", is_bundle: true },
    });
    const ctx = new PricingContext(
      {
        cart: cartPayload({
          metadata: { price_type: "preferred_customer" },
          items: [bundle],
        }),
        cart_item: bundle,
      },
      deps,
    );

    await cartItemAdded(ctx);
    expect(deps.callsTo("updateCartItemsPrices")[0].args[1]).toEqual([
      { id: 1, price: 45 },
    ]);
  });
});

describe("cart_item_updated", () => {
  it("re-affirms the slug alongside the reprice", async () => {
    const deps = recordingDeps();
    const ctx = new PricingContext(
      {
        cart: cartPayload({
          metadata: { price_type: "preferred_customer" },
          items: [line(1)],
        }),
        cart_item: line(1),
      },
      deps,
    );

    await cartItemUpdated(ctx);
    expect(deps.calls.map((c) => c.method)).toEqual([
      "updateCartItemsPrices",
      "appendCartMetadata",
    ]);
  });
});

describe("cart_subscription_added / removed", () => {
  it("stamps BEFORE repricing on subscription_added", async () => {
    const deps = recordingDeps();
    const ctx = new PricingContext(
      { cart: cartPayload({ metadata: {}, items: [line(1)] }) },
      deps,
    );

    await subscriptionAdded(ctx);
    expect(deps.calls.map((c) => c.method)).toEqual([
      "appendCartMetadata",
      "updateCartItemsPrices",
      "recordCartPricingEvent",
    ]);
  });

  it("reverts a guest cart to regular prices when nothing else qualifies", async () => {
    const deps = recordingDeps();
    const ctx = new PricingContext(
      {
        cart: cartPayload({
          email: null,
          metadata: { price_type: "preferred_customer" },
          items: [line(1)],
        }),
      },
      deps,
    );

    await subscriptionRemoved(ctx);
    expect(deps.callsTo("appendCartMetadata")[0].args[1]).toEqual({
      price_type: null,
    });
    expect(deps.callsTo("updateCartItemsPrices")[0].args[1]).toEqual([
      { id: 1, price: 20 },
    ]);
    expect(deps.events[0]).toMatchObject({
      eventType: "item_updated",
      preferredPricingApplied: false,
    });
  });

  it("keeps subscription pricing on a guest cart that still has a subscription line", async () => {
    const deps = recordingDeps();
    const ctx = new PricingContext(
      {
        cart: cartPayload({
          email: null,
          metadata: { price_type: "preferred_customer" },
          items: [line(1, { subscription: true })],
        }),
      },
      deps,
    );

    await subscriptionRemoved(ctx);
    expect(deps.callsTo("appendCartMetadata")[0].args[1]).toEqual({
      price_type: "preferred_customer",
    });
  });

  it("keeps subscription pricing when Exigo still reports an autoship", async () => {
    const deps = recordingDeps({
      enabled: true,
      credentials: CREDENTIALS,
      exigo: exigoStub({ autoshipByEmail: true }),
      fluid: { customers: [{ id: 555 }], subscriptions: { subscriptions: [] } },
    });
    const ctx = new PricingContext(
      {
        cart: cartPayload({
          customer_id: 555,
          metadata: { price_type: "preferred_customer" },
          items: [line(1)],
        }),
      },
      deps,
    );

    await subscriptionRemoved(ctx);
    expect(deps.callsTo("appendCartMetadata")[0].args[1]).toEqual({
      price_type: "preferred_customer",
    });
  });
});

describe("cart_email_on_create", () => {
  it("answers the metadata-carrying body ONLY on the genuine preferred path", async () => {
    const deps = recordingDeps({
      fluid: {
        metafield: { key: "customer_type", value: { customer_type: "preferred_customer" } },
      },
    });
    const ctx = new PricingContext(
      { cart: cartPayload({ customer_id: 555 }) },
      deps,
    );

    await expect(cartEmailOnCreate(ctx)).resolves.toEqual({
      success: true,
      metadata: { price_type: "preferred_customer" },
    });
  });

  it("answers WITHOUT metadata for a regular customer", async () => {
    // This body is also the neutral one the route returns on an auth failure,
    // which is what keeps the route from being an oracle.
    const deps = recordingDeps({
      fluid: { metafield: null, subscriptions: { subscriptions: [] } },
    });
    const ctx = new PricingContext(
      { cart: cartPayload({ customer_id: 555 }) },
      deps,
    );

    const result = await cartEmailOnCreate(ctx);
    expect(result).toEqual({
      success: true,
      message: "Regular customer, no special pricing needed",
    });
    expect(result).not.toHaveProperty("metadata");
  });

  it("never claims preferred for a guest cart, however preferred the email is", async () => {
    // `customer_logged_in? && is_preferred_customer?` — the guest half is
    // checked first, so no lookup is spent either.
    const deps = recordingDeps({
      fluid: {
        metafield: { key: "customer_type", value: { customer_type: "preferred_customer" } },
      },
    });
    const ctx = new PricingContext(
      { cart: cartPayload({ customer_id: null }) },
      deps,
    );

    const result = await cartEmailOnCreate(ctx);
    expect(result).not.toHaveProperty("metadata");
    expect(deps.callsTo("getMetafieldByKey")).toHaveLength(0);
  });

  it("does not write the metafield cache for an installation reading Fluid member types", async () => {
    // The metafield is the EXIGO source's cache. Writing it for a member-type
    // installation would spend Fluid calls on a callback to keep a value
    // nothing reads up to date.
    const deps = recordingDeps({
      settings: { preferred_source: "fluid_member_type" },
      fluid: { memberTypeSlug: "preferred" },
    });
    const ctx = new PricingContext(
      { cart: cartPayload({ customer_id: 555 }) },
      deps,
    );

    await cartEmailOnCreate(ctx);
    expect(deps.callsTo("updateMetafield")).toHaveLength(0);
    expect(deps.callsTo("ensureMetafieldDefinition")).toHaveLength(0);
  });
});

describe("cart_customer_attached", () => {
  it("falls back to the payload's bound customer email when the cart has none", async () => {
    const deps = recordingDeps({
      fluid: { metafield: null, subscriptions: { subscriptions: [{ id: 1 }] } },
    });
    const ctx = new PricingContext(
      {
        cart: cartPayload({ email: null, customer_id: 555, items: [line(1)] }),
        customer: { email: "bound@example.com" },
      },
      deps,
    );

    await cartCustomerAttached(ctx);
    // It got past the "Email is blank" guard and repriced.
    expect(deps.callsTo("updateCartItemsPrices")).toHaveLength(1);
  });

  it("refuses when neither the cart nor the customer object carries an email", async () => {
    const deps = recordingDeps();
    const ctx = new PricingContext(
      { cart: cartPayload({ email: null, customer_id: 555 }) },
      deps,
    );

    await expect(cartCustomerAttached(ctx)).resolves.toEqual({
      success: false,
      message: "Email is blank",
    });
  });
});

describe("cart_country_changed", () => {
  it("touches ONLY the lines this droplet locked", async () => {
    // Everything else core has already repriced at the new country, and writing
    // to it would lock a price Fluid set itself.
    const deps = recordingDeps();
    const ctx = new PricingContext(
      {
        cart: cartPayload({
          metadata: { price_type: "preferred_customer" },
          items: [
            line(1, { metadata: { price_locked: true } }),
            line(2, { metadata: {} }),
          ],
        }),
        context: { country_code: "CA", previous_country_code: "US" },
      },
      deps,
    );

    await cartCountryChanged(ctx);

    expect(deps.callsTo("updateCartItemsPrices")[0].args[1]).toEqual([
      { id: 1, price: 16 },
    ]);
    expect(deps.events[0]).toMatchObject({
      eventType: "country_changed",
      preferredPricingApplied: true,
      metadata: {
        country_code: "CA",
        previous_country_code: "US",
        items_updated: 1,
      },
    });
  });

  it("restores RETAIL prices on the locked lines of a cart that is no longer preferred", async () => {
    // A detached cart still carries lines this droplet locked at retail, and
    // those strand on a country change exactly like the preferred ones. The
    // gate picks WHICH price to restore, not whether to act.
    const deps = recordingDeps({
      fluid: { subscriptions: { subscriptions: [] } },
    });
    const ctx = new PricingContext(
      {
        cart: cartPayload({
          metadata: {},
          items: [line(1, { metadata: { price_locked: true } })],
        }),
      },
      deps,
    );

    const result = await cartCountryChanged(ctx);
    expect(deps.callsTo("updateCartItemsPrices")[0].args[1]).toEqual([
      { id: 1, price: 20 },
    ]);
    expect(result).toEqual({
      success: true,
      message: "Cart repriced for the new country",
    });
    expect(result).not.toHaveProperty("metadata");
  });

  it("does nothing when no line is locked", async () => {
    const deps = recordingDeps();
    const ctx = new PricingContext(
      {
        cart: cartPayload({
          metadata: { price_type: "preferred_customer" },
          items: [line(1)],
        }),
      },
      deps,
    );

    await expect(cartCountryChanged(ctx)).resolves.toEqual({ success: true });
    expect(deps.calls).toHaveLength(0);
  });
});

describe("preferred status via Exigo", () => {
  it("compares CustomerTypeID as a string, so an integer from Exigo still matches", async () => {
    // Exigo returns an Integer; preferred_customer_type_id is the String "2".
    // Comparing them raw is `2 === "2"` — false for every customer.
    const deps = recordingDeps({
      enabled: true,
      credentials: CREDENTIALS,
      settings: { exigo_preferred_signal: "customer_type", preferred_customer_type_id: "2" },
      exigo: exigoStub({ customerTypeByEmail: 2 }),
    });
    const ctx = new PricingContext({ cart: cartPayload() }, deps);

    expect(await ctx.exigoPreferredByEmail("shopper@example.com")).toBe(true);
  });

  it("records a failed Exigo lookup as UNKNOWN, not as retail", async () => {
    const deps = recordingDeps({
      enabled: true,
      credentials: CREDENTIALS,
      exigo: exigoStub({ autoshipByEmail: new Error("SQL Server unreachable") }),
    });
    const ctx = new PricingContext({ cart: cartPayload() }, deps);

    expect(await ctx.exigoPreferredByEmail("shopper@example.com")).toBe(false);
    // The sticky flag is what stops the rollback branch from firing.
    expect(ctx.preferredLookupFailed).toBe(true);
  });

  it("asks the autoship question and the customer-type question under different cache keys", async () => {
    // A company that flips the setting must not read back the other signal's
    // cached answer — they answer different questions.
    const exigo = exigoStub({ autoshipByEmail: true, customerTypeByEmail: 9 });
    const autoship = recordingDeps({
      enabled: true,
      credentials: CREDENTIALS,
      exigo,
    });
    const ctxA = new PricingContext({ cart: cartPayload() }, autoship);
    expect(await ctxA.exigoPreferredByEmail("a@b.com")).toBe(true);

    const byType = recordingDeps({
      enabled: true,
      credentials: CREDENTIALS,
      settings: { exigo_preferred_signal: "customer_type" },
      exigo,
    });
    // A fresh cache would prove nothing, so the SAME cache is reused.
    byType.cache = autoship.cache;
    const ctxB = new PricingContext({ cart: cartPayload() }, byType);
    expect(await ctxB.exigoPreferredByEmail("a@b.com")).toBe(false);
  });
});
