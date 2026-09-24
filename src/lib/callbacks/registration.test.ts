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
  company: { update: vi.fn() },
  fluidCallbackRegistration: {
    findUnique: vi.fn(),
    upsert: vi.fn(),
    deleteMany: vi.fn(),
    count: vi.fn(),
  },
}));

vi.mock("@/lib/db", () => ({ prisma: mockPrisma, default: mockPrisma }));

const { registerCallbacksForCompany, activeCallbacks } = await import(
  "./registration"
);
type FluidClientLike = Parameters<typeof registerCallbacksForCompany>[0];

function mockClient() {
  return {
    createCallback: vi.fn(),
    deleteCallback: vi.fn().mockResolvedValue(undefined),
  };
}

/**
 * The url `activeCallbacks()` builds for the first configured callback, from
 * `FLUID_DROPLET_URL` (set in src/test/setup.ts) and CALLBACK_ROUTES.
 */
const CALLBACK_URL = "https://droplet.test/api/callbacks/cart-item-added";

/**
 * The callbacks are read from `droplet.config.ts` now, not the database, so
 * these cases narrow it to one entry rather than stubbing a table. The real
 * eight are asserted separately, in `activeCallbacks`.
 */
vi.mock("@/lib/config", async (importOriginal) => {
  const actual = await importOriginal<typeof import("@/lib/config")>();
  return {
    ...actual,
    dropletConfig: {
      ...actual.dropletConfig,
      callbacks: [
        {
          enabled: true,
          definition_name: "cart_item_added",
          description: "…",
          timeoutInSeconds: 20,
        },
      ],
    },
  };
});

beforeEach(() => {
  vi.clearAllMocks();
});

describe("registerCallbacksForCompany", () => {
  it("stores only the digest of the returned verification token", async () => {
    const client = mockClient();
    client.createCallback.mockResolvedValue({
      callback_registration: {
        uuid: "cbr_1",
        definition_name: "cart_item_added",
        url: CALLBACK_URL,
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
        url: CALLBACK_URL,
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
        url: CALLBACK_URL,
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

  it("registers the configured callback at the path the table gives it", async () => {
    const client = mockClient();
    client.createCallback.mockResolvedValue({
      callback_registration: {
        uuid: "cbr_1",
        definition_name: "cart_item_added",
        url: CALLBACK_URL,
        active: true,
        verification_token: "cvt_secret",
      },
    });

    await registerCallbacksForCompany(
      client as unknown as FluidClientLike,
      "dri_acme",
    );

    expect(client.createCallback).toHaveBeenCalledWith({
      definition_name: "cart_item_added",
      url: CALLBACK_URL,
      timeout_in_seconds: 20,
      active: true,
    });
  });
});

/**
 * `activeCallbacks` against the REAL config, which is the parity check that
 * replaced the deleted `serves.test.ts`.
 *
 * The table-era guard asked "is this typed url one we serve?". There are no
 * typed urls any more, so the question becomes "does every configured
 * definition have a route, and does every route this droplet serves have a
 * registration?" — the second half being the one that catches a callback
 * silently not registered, which no error would ever reveal.
 */
describe("activeCallbacks", () => {
  it("resolves every configured callback against CALLBACK_ROUTES", async () => {
    const { CALLBACK_ROUTES } = await import("@/lib/pricing/routes-table");
    const { dropletConfig: real } = await vi.importActual<
      typeof import("@/lib/config")
    >("@/lib/config");

    for (const callback of real.callbacks) {
      expect(
        Object.keys(CALLBACK_ROUTES),
        `${callback.definition_name} is configured but this droplet serves no ` +
          "route for it; Fluid would accept the registration and 404 on every " +
          "dispatch",
      ).toContain(callback.definition_name);
    }
  });

  it("configures every route this droplet serves", async () => {
    const { CALLBACK_ROUTES } = await import("@/lib/pricing/routes-table");
    const { dropletConfig: real } = await vi.importActual<
      typeof import("@/lib/config")
    >("@/lib/config");

    const configured = new Set(
      real.callbacks.map((callback) => callback.definition_name),
    );

    for (const definition of Object.keys(CALLBACK_ROUTES)) {
      expect(
        configured,
        `${definition} has a route but no entry in droplet.config.ts, so it is ` +
          "never registered — pricing for it silently never runs",
      ).toContain(definition);
    }
  });

  it("builds each url from FLUID_DROPLET_URL", () => {
    // The mocked single-entry config; the real eight are covered above.
    expect(activeCallbacks()).toEqual([
      {
        name: "cart_item_added",
        url: CALLBACK_URL,
        timeoutInSeconds: 20,
      },
    ]);
  });

  it("registers nothing when FLUID_DROPLET_URL is unset", () => {
    // A registration built on a missing host is one Fluid accepts and never
    // delivers to, with nothing on this side to error.
    const saved = process.env.FLUID_DROPLET_URL;
    delete process.env.FLUID_DROPLET_URL;
    try {
      expect(activeCallbacks()).toEqual([]);
    } finally {
      process.env.FLUID_DROPLET_URL = saved;
    }
  });
});
