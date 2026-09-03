/**
 * `cart_item_added` — a FAIL-CLOSED callback route.
 *
 * Eight of this droplet's nine callbacks fail closed, and this is the
 * highest-volume of them. The properties checked here are the ones that decide
 * whether a shopper is charged correctly by the right tenant:
 *
 *  1. A correctly signed request is served as the tenant the REGISTRATION binds
 *     it to — not the one the body names.
 *  2. Every unverified request is refused with an EXACT 401. Not "non-2xx": a
 *     misconfigured route that 500s on everything would pass that.
 *  3. A payload naming a different company is still served as the
 *     registration's company. This is the cross-tenant defect the Rails app
 *     had, where `find_company` read `cart["company"]["id"]` out of an
 *     unauthenticated body.
 *  4. The Rails controllers' `require`s still produce a 400.
 *
 * The signatures are real. A stub that only implements `json()` never reaches
 * the handler, because the SDK hashes the raw bytes.
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
const OTHER_TOKEN = "cvt_someone_else";

const url = "https://droplet.test/api/callbacks/cart-item-added";

/**
 * A cart that qualifies for NOTHING: no subscription line, no logged-in
 * customer, no Exigo. The engine answers without making a single Fluid call,
 * which keeps this file about the route rather than about pricing.
 */
const plainBody = (cartOverrides: Record<string, unknown> = {}) => ({
  cart: {
    cart_token: "crt_1",
    company: { id: 42 },
    items: [],
    ...cartOverrides,
  },
  cart_item: { id: 9, price: "10.0" },
});

beforeEach(() => {
  vi.clearAllMocks();
  mockPrisma.fluidCallbackRegistration.findUnique.mockImplementation(
    async ({ where }: { where: { tokenDigest: string } }) =>
      where.tokenDigest === tokenDigest(TOKEN)
        ? registrationFixture({
            tokenDigest: tokenDigest(TOKEN),
            definitionName: "cart_item_added",
          })
        : null,
  );
  mockPrisma.integrationSetting.findFirst.mockResolvedValue(null);
});

describe("POST /api/callbacks/cart-item-added", () => {
  it("serves a correctly signed callback as the registration's tenant", async () => {
    mockPrisma.company.findFirst.mockResolvedValue(companyFixture());

    const response = await POST(
      signedCallbackRequest({ url, token: TOKEN, body: plainBody() }),
    );

    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toEqual({
      success: true,
      message: "Cart does not have preferred_customer pricing",
    });

    // The tenant was looked up by the registration's dri, and by nothing else.
    expect(mockPrisma.company.findFirst).toHaveBeenCalledWith({
      where: {
        dropletInstallationUuid: "dri_acme",
        active: true,
        uninstalledAt: null,
      },
    });
  });

  it("refuses an unknown token with 401", async () => {
    mockPrisma.company.findFirst.mockResolvedValue(companyFixture());

    const response = await POST(
      signedCallbackRequest({ url, token: OTHER_TOKEN, body: plainBody() }),
    );

    // Exactly 401. Fluid discards this status — CartItemCallbackSubscriber
    // throws away the return value of Callback::Client.request — so refusing
    // costs the cart nothing and is the only thing that raises an alert.
    expect(response.status).toBe(401);
    await expect(response.json()).resolves.toEqual({ error: "unauthorized" });

    // The handler never ran: no tenant was ever resolved.
    expect(mockPrisma.company.findFirst).not.toHaveBeenCalled();
  });

  it("refuses a valid token whose signature was made with a different key", async () => {
    mockPrisma.company.findFirst.mockResolvedValue(companyFixture());

    const response = await POST(
      signedCallbackRequest({
        url,
        token: TOKEN,
        signingToken: "not-the-token",
        body: plainBody(),
      }),
    );

    expect(response.status).toBe(401);
    expect(mockPrisma.company.findFirst).not.toHaveBeenCalled();
  });

  it("serves a payload naming a different company as the registration's company", async () => {
    mockPrisma.company.findFirst.mockResolvedValue(companyFixture());

    const response = await POST(
      signedCallbackRequest({
        url,
        token: TOKEN,
        // Acme's token, signing a body whose cart claims to belong to company
        // 999. Rails resolved the tenant from exactly this field.
        body: plainBody({ company: { id: 999 } }),
      }),
    );

    expect(response.status).toBe(200);
    expect(mockPrisma.company.findFirst).toHaveBeenCalledTimes(1);
    expect(mockPrisma.company.findFirst).toHaveBeenCalledWith(
      expect.objectContaining({
        where: expect.objectContaining({ dropletInstallationUuid: "dri_acme" }),
      }),
    );
  });

  it("refuses a token issued for a definition this route does not serve", async () => {
    mockPrisma.fluidCallbackRegistration.findUnique.mockResolvedValue(
      registrationFixture({
        tokenDigest: tokenDigest(TOKEN),
        definitionName: "cart_country_changed",
      }),
    );
    mockPrisma.company.findFirst.mockResolvedValue(companyFixture());

    const response = await POST(
      signedCallbackRequest({ url, token: TOKEN, body: plainBody() }),
    );

    expect(response.status).toBe(401);
    expect(mockPrisma.company.findFirst).not.toHaveBeenCalled();
  });

  it("refuses when the registration resolves to no active company", async () => {
    // A company that has uninstalled, or a dri that no longer matches. A null
    // principal is an auth failure: guessing a tenant would be worse than
    // declining.
    mockPrisma.company.findFirst.mockResolvedValue(null);

    const response = await POST(
      signedCallbackRequest({ url, token: TOKEN, body: plainBody() }),
    );

    expect(response.status).toBe(401);
  });

  it("refuses rather than 500s when the token store is unavailable", async () => {
    // The shape of deploying the Prisma model without the Rails migration: the
    // table is missing, the store throws, and the SDK reads that as an auth
    // failure rather than as "unverified but probably fine".
    mockPrisma.fluidCallbackRegistration.findUnique.mockRejectedValue(
      new Error("relation \"fluid_callback_registrations\" does not exist"),
    );
    mockPrisma.company.findFirst.mockResolvedValue(companyFixture());

    const response = await POST(
      signedCallbackRequest({ url, token: TOKEN, body: plainBody() }),
    );

    expect(response.status).toBe(401);
    expect(mockPrisma.company.findFirst).not.toHaveBeenCalled();
  });

  it("answers 400 when the payload is missing a field the Rails controller required", async () => {
    mockPrisma.company.findFirst.mockResolvedValue(companyFixture());

    const response = await POST(
      signedCallbackRequest({
        url,
        token: TOKEN,
        // No cart_item — `permitted.require(:cart_item)` in Rails, 400 there.
        body: { cart: { cart_token: "crt_1", company: { id: 42 }, items: [] } },
      }),
    );

    expect(response.status).toBe(400);
    await expect(response.json()).resolves.toEqual({
      success: false,
      error: "param is missing or the value is empty: cart_item",
    });
  });
});
