/**
 * `cart_email_on_create` — the ONE fail-open route, and the one whose response
 * body Fluid writes onto the cart.
 *
 * The two things that must hold, and that no other route in this droplet cares
 * about:
 *
 *  1. Every failure — unknown token, bad signature, unresolvable tenant,
 *     malformed body, handler blow-up — answers an EXACT 200 with an EXACT
 *     `{"success": true}` and NOTHING else. A non-2xx here silently drops the
 *     cart's price_type stamp, because `enrich_cart_metadata` skips a response
 *     unless `response.success?`, which is the HTTP status.
 *  2. The neutral body carries NO `metadata`. `enrich_cart_metadata` merges
 *     `response.metadata` into `cart.metadata` with `update_column`, so a
 *     neutral body carrying `{price_type: "preferred_customer"}` would stamp
 *     preferred pricing onto a cart that had not earned it — on an AUTH
 *     FAILURE, which is the worst possible moment.
 *
 * The genuine-preferred path is exercised too, so that the neutral assertions
 * cannot pass by the route simply never producing metadata at all. That is the
 * failure this file exists to catch: a test that only asserts the rejection
 * path would still pass against a route that answered `{success: true}` to
 * everything.
 */

import { describe, it, expect, vi, beforeEach } from "vitest";
import { tokenDigest } from "@fluid-app/droplet-sdk";

import { companyFixture, registrationFixture } from "@/test/factories";
import { signedCallbackRequest } from "@/test/signing";

const mockPrisma = vi.hoisted(() => ({
  company: { findFirst: vi.fn() },
  integrationSetting: { findFirst: vi.fn() },
  cartPricingEvent: { create: vi.fn() },
  fluidCallbackRegistration: {
    findUnique: vi.fn(),
    upsert: vi.fn(),
    deleteMany: vi.fn(),
    count: vi.fn(),
  },
}));

vi.mock("@/lib/db", () => ({ prisma: mockPrisma, default: mockPrisma }));

const { POST } = await import("./route");

const TOKEN = "cvt_acme_token";
const url = "https://droplet.test/api/callbacks/cart-email-on-create";

/** The exact neutral body. Asserted with toEqual, so an extra key fails. */
const NEUTRAL = { success: true };

const body = (cart: Record<string, unknown> = {}) => ({
  cart: {
    cart_token: "crt_1",
    company: { id: 42 },
    email: "shopper@example.com",
    items: [],
    ...cart,
  },
});

beforeEach(() => {
  vi.clearAllMocks();
  mockPrisma.fluidCallbackRegistration.findUnique.mockImplementation(
    async ({ where }: { where: { tokenDigest: string } }) =>
      where.tokenDigest === tokenDigest(TOKEN)
        ? registrationFixture({
            tokenDigest: tokenDigest(TOKEN),
            definitionName: "cart_email_on_create",
            url,
          })
        : null,
  );
  mockPrisma.integrationSetting.findFirst.mockResolvedValue(null);
  mockPrisma.company.findFirst.mockResolvedValue(companyFixture());
});

describe("POST /api/callbacks/cart-email-on-create", () => {
  it("answers 200 with the bare neutral body when the token is unknown", async () => {
    const response = await POST(
      signedCallbackRequest({ url, token: "cvt_not_ours", body: body() }),
    );

    expect(response.status).toBe(200);
    // toEqual, not toMatchObject: `metadata` must be ABSENT, not merely
    // different.
    await expect(response.json()).resolves.toEqual(NEUTRAL);
    expect(mockPrisma.company.findFirst).not.toHaveBeenCalled();
  });

  it("answers 200 with the bare neutral body when the signature is forged", async () => {
    const response = await POST(
      signedCallbackRequest({
        url,
        token: TOKEN,
        signingToken: "not-the-token",
        body: body(),
      }),
    );

    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toEqual(NEUTRAL);
  });

  it("answers 200 with the bare neutral body when the tenant cannot be resolved", async () => {
    mockPrisma.company.findFirst.mockResolvedValue(null);

    const response = await POST(
      signedCallbackRequest({ url, token: TOKEN, body: body() }),
    );

    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toEqual(NEUTRAL);
  });

  it("answers 200 with the bare neutral body when a required field is missing", async () => {
    const response = await POST(
      signedCallbackRequest({
        url,
        token: TOKEN,
        // No email — `cart.require(:email)` in Rails, which answered 400 there.
        body: { cart: { cart_token: "crt_1", company: { id: 42 } } },
      }),
    );

    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toEqual(NEUTRAL);
  });

  it("answers the same bare body for a genuine non-preferred cart, so it is not an oracle", async () => {
    const refused = await POST(
      signedCallbackRequest({ url, token: "cvt_not_ours", body: body() }),
    );
    const served = await POST(
      signedCallbackRequest({ url, token: TOKEN, body: body() }),
    );

    expect(served.status).toBe(refused.status);
    // The legitimate "regular customer" answer carries a message; the neutral
    // one does not — so this asserts the STATUS and the absence of metadata,
    // which is what an attacker could actually distinguish on.
    const servedBody = (await served.json()) as Record<string, unknown>;
    expect(servedBody.success).toBe(true);
    expect(servedBody).not.toHaveProperty("metadata");
  });

  it("DOES carry metadata on the genuine preferred path", async () => {
    // Without this the neutral assertions above would pass against a route that
    // answered `{success: true}` to absolutely everything, which would be a
    // droplet that had silently stopped applying preferred pricing.
    mockPrisma.integrationSetting.findFirst.mockResolvedValue({
      id: 1n,
      companyId: 1n,
      enabled: false,
      settings: {},
      credentials: {},
    });

    const fetchMock = vi.fn(async (input: string | URL | Request) => {
      const href = String(input instanceof Request ? input.url : input);
      // The customer has an active Fluid subscription, which is one of the
      // three ways isPreferredCustomer answers true.
      if (href.includes("/api/subscriptions")) {
        return Response.json({ subscriptions: [{ id: 7 }] });
      }
      if (href.includes("/api/v2/metafields?")) {
        return Response.json({
          metafields: [
            { key: "customer_type", value: { customer_type: "preferred_customer" } },
          ],
        });
      }
      return Response.json({});
    });
    vi.stubGlobal("fetch", fetchMock);

    const response = await POST(
      signedCallbackRequest({
        url,
        token: TOKEN,
        body: body({ customer_id: 555 }),
      }),
    );

    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toEqual({
      success: true,
      metadata: { price_type: "preferred_customer" },
    });

    vi.unstubAllGlobals();
  });
});
