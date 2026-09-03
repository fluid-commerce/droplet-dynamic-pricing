/**
 * The guards whose failure mode is a wrong charge rather than an error.
 *
 * Each of these traces to a shipped incident, and each is the kind of check
 * that looks redundant until you know why it is there. The tests exist so that
 * a later simplification has to argue with a failing assertion instead of with
 * a comment.
 */

import { describe, it, expect } from "vitest";

import { PricingContext } from "./context";
import {
  cartCustomerDetached,
  cartItemAdded,
  customerLoggedIn,
} from "./services";
import { cartPayload, recordingDeps } from "@/test/pricing";
import type { Json } from "./types";

const priced = (id: number, price: string): Json => ({
  id,
  variant_id: null,
  quantity: 1,
  price,
  product: { price },
  metadata: {},
});

describe("the settled-cart guard (CURRENT-3361)", () => {
  it.each([["payment_authorized"], ["payment_captured"]])(
    "writes nothing to a cart in state %s",
    async (state) => {
      const deps = recordingDeps();
      const ctx = new PricingContext(
        {
          cart: cartPayload({
            state,
            metadata: { price_type: "preferred_customer" },
            items: [priced(1, "10.0")],
          }),
          cart_item: priced(1, "10.0"),
        },
        deps,
      );

      await expect(cartItemAdded(ctx)).resolves.toEqual({ success: true });
      expect(deps.calls).toHaveLength(0);
    },
  );

  it("writes nothing when the trigger is order_completion, whatever state the cart reports", async () => {
    // The incident needed BOTH signals: the order_completion attach still
    // reported a mutable-looking cart on one payload.
    const deps = recordingDeps();
    const ctx = new PricingContext(
      {
        cart: cartPayload({
          state: "open",
          metadata: { price_type: "preferred_customer" },
          items: [priced(1, "10.0")],
        }),
        cart_item: priced(1, "10.0"),
        context: { trigger_source: "order_completion" },
      },
      deps,
    );

    await expect(cartItemAdded(ctx)).resolves.toEqual({ success: true });
    expect(deps.calls).toHaveLength(0);
  });

  it("keeps repricing a cart in a state the denylist has never seen", async () => {
    // A DENYLIST, not an allowlist: a new state must fall through to "reprice"
    // and let Fluid's own 410 be the backstop, rather than silently switching
    // pricing off on every live cart.
    const deps = recordingDeps();
    const ctx = new PricingContext(
      {
        cart: cartPayload({
          state: "some_new_state_fluid_added",
          metadata: { price_type: "preferred_customer" },
          items: [priced(1, "10.0")],
        }),
        cart_item: priced(1, "10.0"),
      },
      deps,
    );

    await cartItemAdded(ctx);
    expect(deps.callsTo("updateCartItemsPrices")).toHaveLength(1);
  });

  it("refuses the write even if a service forgot the early return", async () => {
    // The guard is enforced at every write, not only at the top of each
    // service, so a path added later still cannot charge-then-reprice.
    const deps = recordingDeps();
    const ctx = new PricingContext(
      { cart: cartPayload({ state: "payment_captured" }) },
      deps,
    );

    await ctx.updateCartItemsPrices([{ id: 1, price: 5 }]);
    await ctx.updateCartMetadata({ price_type: "preferred_customer" });

    expect(deps.calls).toHaveLength(0);
    expect(deps.logs.warn.join("\n")).toContain("Refusing to write prices");
  });
});

describe("the zero-price guard", () => {
  it("drops zero-priced lines and keeps the rest", async () => {
    // A zero written here is an admin override that Fluid LOCKS, so the right
    // price can never come back on its own.
    const deps = recordingDeps();
    const ctx = new PricingContext({ cart: cartPayload() }, deps);

    await ctx.updateCartItemsPrices([
      { id: 1, price: 0 },
      { id: 2, price: 9.99 },
    ]);

    expect(deps.callsTo("updateCartItemsPrices")[0].args[1]).toEqual([
      { id: 2, price: 9.99 },
    ]);
    expect(deps.logs.warn.join("\n")).toContain("Refusing to set zero price");
  });

  it("makes no call at all when every line is zero", async () => {
    const deps = recordingDeps();
    const ctx = new PricingContext({ cart: cartPayload() }, deps);

    await ctx.updateCartItemsPrices([{ id: 1, price: 0 }]);

    expect(deps.callsTo("updateCartItemsPrices")).toHaveLength(0);
  });

  it("treats an empty list as a deliberate no-op, not an error", async () => {
    // Empty means every item was refused by countrySafePrice, which already
    // logged why.
    const deps = recordingDeps();
    const ctx = new PricingContext({ cart: cartPayload() }, deps);

    await expect(ctx.updateCartItemsPrices([])).resolves.toBeUndefined();
    expect(deps.callsTo("updateCartItemsPrices")).toHaveLength(0);
  });
});

describe('"unknown" is never read as "not preferred" (CURRENT-3361)', () => {
  const stampedCart = () =>
    cartPayload({
      customer_id: 555,
      metadata: { price_type: "preferred_customer" },
      items: [priced(1, "10.0")],
    });

  it("strips the discount when the customer is genuinely not preferred", async () => {
    const deps = recordingDeps({
      fluid: { subscriptions: { subscriptions: [] }, metafield: null },
    });
    const ctx = new PricingContext({ cart: stampedCart() }, deps);

    await customerLoggedIn(ctx);

    // A definite negative: the metafield answered, and the subscriptions
    // response carried the key. Rolling back to retail is correct here.
    expect(deps.callsTo("appendCartMetadata")[0].args[1]).toEqual({
      price_type: null,
    });
    expect(deps.callsTo("updateCartItemsPrices")).toHaveLength(1);
  });

  it("does NOT strip the discount when a lookup failed", async () => {
    // This is the assertion the guard exists for. Without it, one transient
    // Fluid failure rewrites every line to retail and the shopper is charged
    // full price.
    const deps = recordingDeps({
      fluid: { subscriptions: { subscriptions: [] } },
    });
    // Make the metafield read throw, which is what
    // notePreferredLookupFailure keys off.
    deps.fluid.getMetafieldByKey = async () => {
      throw new Error("Fluid timed out");
    };

    const ctx = new PricingContext({ cart: stampedCart() }, deps);
    await customerLoggedIn(ctx);

    expect(deps.callsTo("appendCartMetadata")).toHaveLength(0);
    expect(deps.callsTo("updateCartItemsPrices")).toHaveLength(0);
  });

  it("does NOT strip the discount while a subscription line remains in the cart", async () => {
    const deps = recordingDeps({
      fluid: { subscriptions: { subscriptions: [] }, metafield: null },
    });
    const ctx = new PricingContext(
      {
        cart: cartPayload({
          customer_id: 555,
          metadata: { price_type: "preferred_customer" },
          items: [{ ...priced(1, "10.0"), subscription: true }],
        }),
      },
      deps,
    );

    await customerLoggedIn(ctx);
    expect(deps.callsTo("appendCartMetadata")).toHaveLength(0);
  });

  it("does not cache a subscriptions response that carried no subscriptions key", async () => {
    // An empty body, a `{}`, or an error object served 200 all collapse to
    // "no subscriptions" — and that false is what unlocks the strip branch.
    // Caching it would spread one degenerate response across every cart of
    // this customer for the whole window.
    const deps = recordingDeps({ fluid: { subscriptions: {} } });
    const ctx = new PricingContext({ cart: cartPayload() }, deps);

    expect(await ctx.hasActiveSubscriptions(555)).toBe(false);
    expect(await ctx.hasActiveSubscriptions(555)).toBe(false);

    expect(deps.callsTo("listSubscriptionsByCustomer")).toHaveLength(2);
    expect(deps.logs.warn.join("\n")).toContain("without a");
  });

  it("DOES cache a real answer, so an N-line add is not N lookups", async () => {
    const deps = recordingDeps({
      fluid: { subscriptions: { subscriptions: [{ id: 1 }] } },
    });
    const ctx = new PricingContext({ cart: cartPayload() }, deps);

    expect(await ctx.hasActiveSubscriptions(555)).toBe(true);
    expect(await ctx.hasActiveSubscriptions(555)).toBe(true);

    expect(deps.callsTo("listSubscriptionsByCustomer")).toHaveLength(1);
  });
});

describe("cart_customer_detached only rolls back pricing this droplet applied", () => {
  it("does nothing to an UNSTAMPED cart", async () => {
    // Rewriting every line to product.price on a mere logout would clobber
    // whatever else set those prices — another droplet, a promo — and was one
    // half of the oscillating pair in CURRENT-3361.
    const deps = recordingDeps();
    const ctx = new PricingContext(
      { cart: cartPayload({ metadata: {}, items: [priced(1, "10.0")] }) },
      deps,
    );

    await expect(cartCustomerDetached(ctx)).resolves.toEqual({ success: true });
    expect(deps.calls).toHaveLength(0);
  });

  it("rolls a STAMPED cart back to regular prices", async () => {
    const deps = recordingDeps();
    const ctx = new PricingContext(
      {
        cart: cartPayload({
          metadata: { price_type: "preferred_customer" },
          items: [priced(1, "10.0")],
        }),
      },
      deps,
    );

    await cartCustomerDetached(ctx);

    expect(deps.callsTo("appendCartMetadata")[0].args[1]).toEqual({
      price_type: null,
    });
    expect(deps.callsTo("updateCartItemsPrices")[0].args[1]).toEqual([
      { id: 1, price: 10 },
    ]);
  });

  it("keeps subscription pricing while a subscription line remains", async () => {
    const deps = recordingDeps();
    const ctx = new PricingContext(
      {
        cart: cartPayload({
          metadata: { price_type: "preferred_customer" },
          items: [{ ...priced(1, "10.0"), subscription: true, subscription_price: "8.0" }],
        }),
      },
      deps,
    );

    await cartCustomerDetached(ctx);

    expect(deps.callsTo("appendCartMetadata")[0].args[1]).toEqual({
      price_type: "preferred_customer",
    });
    expect(deps.callsTo("updateCartItemsPrices")[0].args[1]).toEqual([
      { id: 1, price: 8 },
    ]);
  });
});

describe("the yield to the BP wholesale droplet", () => {
  const enrollmentCart = () =>
    cartPayload({
      type: "enrollment",
      metadata: { price_type: "preferred_customer" },
      items: [priced(1, "10.0")],
    });

  it("does NOT yield on an enrollment cart when the company has not opted in", async () => {
    // STU2-2377: yielding for everyone would strip preferred-customer pricing
    // from every other company's enrollment carts.
    const deps = recordingDeps({ settings: {} });
    const ctx = new PricingContext(
      { cart: enrollmentCart(), cart_item: priced(1, "10.0") },
      deps,
    );

    await cartItemAdded(ctx);
    expect(deps.callsTo("updateCartItemsPrices")).toHaveLength(1);
  });

  it("yields on an enrollment cart when the company HAS opted in", async () => {
    const deps = recordingDeps({
      settings: { yield_to_enrollment_wholesale: true },
    });
    const ctx = new PricingContext(
      { cart: enrollmentCart(), cart_item: priced(1, "10.0") },
      deps,
    );

    await expect(cartItemAdded(ctx)).resolves.toEqual({ success: true });
    expect(deps.calls).toHaveLength(0);
  });

  it('yields on any cart stamped price_type "wholesale", toggle or not (STU2-2964)', async () => {
    const deps = recordingDeps({ settings: {} });
    const ctx = new PricingContext(
      {
        cart: cartPayload({
          metadata: { price_type: "wholesale" },
          items: [priced(1, "10.0")],
        }),
        cart_item: priced(1, "10.0"),
      },
      deps,
    );

    await expect(cartItemAdded(ctx)).resolves.toEqual({ success: true });
    expect(deps.calls).toHaveLength(0);
  });

  it('treats the STRING "false" on the toggle as false, the way Rails does', async () => {
    // ActiveModel::Type::Boolean, not JavaScript truthiness. A bare
    // Boolean("false") is true, which would hand every enrollment cart to a
    // droplet that may not even be installed.
    const deps = recordingDeps({
      settings: { yield_to_enrollment_wholesale: "false" },
    });
    const ctx = new PricingContext(
      { cart: enrollmentCart(), cart_item: priced(1, "10.0") },
      deps,
    );

    await cartItemAdded(ctx);
    expect(deps.callsTo("updateCartItemsPrices")).toHaveLength(1);
  });
});

describe("locked cart items", () => {
  it("selects only the lines carrying metadata.price_locked === true", async () => {
    const deps = recordingDeps();
    const ctx = new PricingContext(
      {
        cart: cartPayload({
          items: [
            { id: 1, metadata: { price_locked: true } },
            { id: 2, metadata: { price_locked: false } },
            { id: 3, metadata: {} },
            // Truthy but not `true`: Fluid stamps a boolean, and a looser check
            // would sweep in lines core repriced itself.
            { id: 4, metadata: { price_locked: "true" } },
          ],
        }),
      },
      deps,
    );

    expect(ctx.lockedCartItems.map((i) => i.id)).toEqual([1]);
  });
});
