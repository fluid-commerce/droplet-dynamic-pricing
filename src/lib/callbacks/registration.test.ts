/**
 * Registration must persist the verification token, or undo itself.
 *
 * Fluid returns `verification_token` only on create — `before_create
 * :set_tokens` is its only writer, and the update action refuses the field. A
 * registration whose token was not captured is live, unverifiable, and (because
 * callback routes answer 200 whatever happens) silent. So the only safe outcome
 * of a failed capture is to delete what was just created.
 */

import { describe, it, expect, vi, beforeEach } from "vitest";
import { tokenDigest } from "@fluid-app/droplet-sdk";

const mockPrisma = vi.hoisted(() => ({
  callback: { findMany: vi.fn() },
  company: { update: vi.fn() },
  fluidCallbackRegistration: {
    findUnique: vi.fn(),
    upsert: vi.fn(),
    deleteMany: vi.fn(),
    count: vi.fn(),
  },
}));

vi.mock("@/lib/db", () => ({ prisma: mockPrisma, default: mockPrisma }));

const { registerCallbacksForCompany } = await import("./registration");
type FluidClientLike = Parameters<typeof registerCallbacksForCompany>[0];

function mockClient() {
  return {
    createCallback: vi.fn(),
    deleteCallback: vi.fn().mockResolvedValue(undefined),
  };
}

const CALLBACK_ROW = {
  id: 1n,
  name: "cart_item_added",
  description: "…",
  url: "https://droplet.test/api/callbacks/cart-item-added",
  timeoutInSeconds: 20,
  active: true,
  createdAt: new Date(),
  updatedAt: new Date(),
};

beforeEach(() => {
  vi.clearAllMocks();
  mockPrisma.callback.findMany.mockResolvedValue([CALLBACK_ROW]);
});

describe("registerCallbacksForCompany", () => {
  it("stores only the digest of the returned verification token", async () => {
    const client = mockClient();
    client.createCallback.mockResolvedValue({
      callback_registration: {
        uuid: "cbr_1",
        definition_name: "cart_item_added",
        url: CALLBACK_ROW.url,
        active: true,
        verification_token: "cvt_secret",
      },
    });

    const results = await registerCallbacksForCompany(
      client as unknown as FluidClientLike,
      "dri_acme",
    );

    expect(results.success).toBe(1);
    expect(results.registeredUuids).toEqual(["cbr_1"]);

    const written = mockPrisma.fluidCallbackRegistration.upsert.mock
      .calls[0][0] as { create: Record<string, unknown> };
    expect(written.create.tokenDigest).toBe(tokenDigest("cvt_secret"));
    // The plaintext must not appear anywhere in what was written.
    expect(JSON.stringify(written)).not.toContain("cvt_secret");
  });

  it("deletes the registration when Fluid returns no verification token", async () => {
    const client = mockClient();
    client.createCallback.mockResolvedValue({
      callback_registration: {
        uuid: "cbr_orphan",
        definition_name: "cart_item_added",
        url: CALLBACK_ROW.url,
        active: true,
        // no verification_token
      },
    });

    const results = await registerCallbacksForCompany(
      client as unknown as FluidClientLike,
      "dri_acme",
    );

    expect(client.deleteCallback).toHaveBeenCalledWith("cbr_orphan");
    expect(results.success).toBe(0);
    expect(results.failed).toBe(1);
    expect(results.registeredUuids).toEqual([]);
    expect(results.errors[0].error).toContain("verification_token");
  });

  it("deletes the registration when the digest cannot be written", async () => {
    const client = mockClient();
    client.createCallback.mockResolvedValue({
      callback_registration: {
        uuid: "cbr_2",
        definition_name: "cart_item_added",
        url: CALLBACK_ROW.url,
        active: true,
        verification_token: "cvt_secret",
      },
    });
    mockPrisma.fluidCallbackRegistration.upsert.mockRejectedValue(
      new Error("database is read only"),
    );

    const results = await registerCallbacksForCompany(
      client as unknown as FluidClientLike,
      "dri_acme",
    );

    expect(client.deleteCallback).toHaveBeenCalledWith("cbr_2");
    expect(results.failed).toBe(1);
  });

  it("does not attempt a rollback when Fluid returns no uuid", async () => {
    // Nothing addressable was created, so there is nothing to delete.
    const client = mockClient();
    client.createCallback.mockResolvedValue({ callback_registration: {} });

    const results = await registerCallbacksForCompany(
      client as unknown as FluidClientLike,
      "dri_acme",
    );

    expect(client.deleteCallback).not.toHaveBeenCalled();
    expect(results.failed).toBe(1);
    expect(results.errors[0].error).toContain("uuid");
  });

  it("registers nothing without a droplet_installation_uuid", async () => {
    // A stored digest whose dri resolves to no tenant would verify and then
    // fail principal resolution — an auth failure on a fail-open route, i.e.
    // silence. Better to not register at all.
    const client = mockClient();

    const results = await registerCallbacksForCompany(
      client as unknown as FluidClientLike,
      "",
    );

    expect(client.createCallback).not.toHaveBeenCalled();
    expect(results.success).toBe(0);
  });

  it("skips rows that are active but have no url or timeout", async () => {
    mockPrisma.callback.findMany.mockResolvedValue([
      { ...CALLBACK_ROW, url: null },
      { ...CALLBACK_ROW, id: 2n, timeoutInSeconds: null },
    ]);
    const client = mockClient();

    const results = await registerCallbacksForCompany(
      client as unknown as FluidClientLike,
      "dri_acme",
    );

    expect(client.createCallback).not.toHaveBeenCalled();
    expect(results.success).toBe(0);
    expect(results.failed).toBe(0);
  });
});
