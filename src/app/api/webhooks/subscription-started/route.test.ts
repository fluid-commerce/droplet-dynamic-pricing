/**
 * `subscription.started` — the regression test for the fleet's shared-token
 * hole (F5).
 *
 * `Webhooks::BaseController#valid_auth_token?` accepted an `AUTH_TOKEN` header
 * that was `include?`-equal to EITHER the company's own
 * `webhook_verification_token` OR `Setting.fluid_webhook.auth_token` — one
 * droplet-wide value, seeded as `"change-me"`. The company came from the
 * caller's payload. So one shared token authenticated a webhook about ANY
 * company, and flipping any customer of any installation between preferred and
 * retail pricing needed nothing else.
 *
 * The assertions below are the two halves of closing it: the company's own key
 * verifies, and the shared bootstrap key does not.
 */

import { describe, it, expect, vi, beforeEach } from "vitest";

import { companyFixture } from "@/test/factories";
import { signedWebhookRequest } from "@/test/signing";

const mockPrisma = vi.hoisted(() => ({
  company: { findFirst: vi.fn() },
  integrationSetting: { findFirst: vi.fn() },
  customerTypeTransaction: { create: vi.fn() },
}));

vi.mock("@/lib/db", () => ({ prisma: mockPrisma, default: mockPrisma }));

const url = "https://droplet.test/api/webhooks/subscription-started";
const SHARED = "shared-droplet-webhook-token";

// Set BEFORE the route module is imported. The route reads
// process.env.FLUID_WEBHOOK_AUTH_TOKEN when the handler is constructed, which
// is at import time — setting it in beforeEach would leave the shared secret
// undefined and make the "refuses the shared token" assertion pass for the
// wrong reason.
process.env.FLUID_WEBHOOK_AUTH_TOKEN = SHARED;

const { POST } = await import("./route");

/**
 * The shape Fluid actually delivers.
 *
 * `Webhook#enrich_payload` merges `event_name`, `company_id`, `resource_name`,
 * `resource` and `event` into the body, which is why the Rails controller
 * permitted exactly those keys. The `resource` + `event` pair matters here: it
 * is what the SDK's `eventOf` reads, and therefore what decides whether a
 * request is eligible for a bootstrap secret. A test body without it would make
 * every event "unknown" and quietly stop testing the bootstrap rule at all.
 */
const body = {
  event_name: "subscription.started",
  schema_version: 1,
  company_id: 42,
  resource_name: "Subscription",
  resource: "subscription",
  event: "started",
  subscription: { id: 3, customer: { id: 555, external_id: "EX555" } },
};

beforeEach(() => {
  vi.clearAllMocks();
  mockPrisma.company.findFirst.mockResolvedValue(companyFixture());
  mockPrisma.integrationSetting.findFirst.mockResolvedValue(null);
  // The handler makes real Fluid calls once it is past auth; a blank JSON
  // answer is enough for the auth assertions and keeps the network out.
  vi.stubGlobal(
    "fetch",
    vi.fn(async () => Response.json({})),
  );
});

describe("POST /api/webhooks/subscription-started", () => {
  it("accepts a webhook signed with the COMPANY's own verification token", async () => {
    const response = await POST(
      signedWebhookRequest({ url, secret: "wvt_acme", body }),
    );

    expect(response.status).toBe(200);
    expect(mockPrisma.company.findFirst).toHaveBeenCalledWith({
      where: { fluidCompanyId: 42n },
    });
  });

  it("REFUSES a webhook signed with the shared droplet-wide token", async () => {
    // This is the whole point. `bootstrapSecret` is deliberately not passed to
    // this route, so the shared value is not a candidate key at all — a leaked
    // copy can no longer authenticate a webhook about somebody else's company.
    const response = await POST(
      signedWebhookRequest({ url, secret: SHARED, body }),
    );

    expect(response.status).toBe(401);
    await expect(response.json()).resolves.toEqual({ error: "unauthorized" });
    expect(mockPrisma.customerTypeTransaction.create).not.toHaveBeenCalled();
  });

  it("REFUSES a webhook signed with a DIFFERENT company's verification token", async () => {
    const response = await POST(
      signedWebhookRequest({ url, secret: "wvt_someone_else", body }),
    );

    expect(response.status).toBe(401);
    expect(mockPrisma.customerTypeTransaction.create).not.toHaveBeenCalled();
  });

  it("refuses when the named company has no verification token to check against", async () => {
    // A blank value can never be an HMAC key, and an installation that cannot
    // be verified must not be served.
    mockPrisma.company.findFirst.mockResolvedValue(
      companyFixture({ webhookVerificationToken: null }),
    );

    const response = await POST(
      signedWebhookRequest({ url, secret: "wvt_acme", body }),
    );

    expect(response.status).toBe(401);
  });

  it("resolves the company from the X-Fluid-Shop header when the body names none", async () => {
    // A subscription payload carries `subscription`, not `company`, so the
    // header is the only hint on some deliveries.
    const response = await POST(
      signedWebhookRequest({
        url,
        secret: "wvt_acme",
        body: {
          resource: "subscription",
          event: "started",
          subscription: { id: 3, customer: { id: 555 } },
        },
        headers: { "x-fluid-shop": "acme.fluid.app" },
      }),
    );

    expect(response.status).toBe(200);
    expect(mockPrisma.company.findFirst).toHaveBeenCalledWith({
      where: { fluidShop: "acme.fluid.app" },
    });
  });

  it("answers 400 when the payload carries no customer id", async () => {
    const response = await POST(
      signedWebhookRequest({
        url,
        secret: "wvt_acme",
        body: {
          resource: "subscription",
          event: "started",
          company_id: 42,
          subscription: { id: 3 },
        },
      }),
    );

    expect(response.status).toBe(400);
    await expect(response.json()).resolves.toEqual({
      success: false,
      error: "Customer ID not found in webhook params",
    });
  });
});
