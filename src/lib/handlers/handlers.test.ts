/**
 * Install and uninstall handling.
 */

import { describe, it, expect, vi, beforeEach } from "vitest";

import { companyFixture } from "@/test/factories";

const mockPrisma = vi.hoisted(() => ({
  company: {
    findFirst: vi.fn(),
    findUnique: vi.fn(),
    create: vi.fn(),
    update: vi.fn(),
  },
  callback: { findMany: vi.fn() },
  fluidCallbackRegistration: {
    findUnique: vi.fn(),
    upsert: vi.fn(),
    deleteMany: vi.fn(async () => ({ count: 0 })),
    count: vi.fn(),
  },
}));

const registerCallbacksForCompany = vi.hoisted(() =>
  vi.fn(async () => ({
    success: 1,
    failed: 0,
    registeredUuids: ["cbr_1"],
    errors: [],
  })),
);
const cleanupCallbacksForCompany = vi.hoisted(() => vi.fn(async () => {}));
const deleteForInstallation = vi.hoisted(() => vi.fn(async () => {}));

vi.mock("@/lib/db", () => ({ prisma: mockPrisma, default: mockPrisma }));
vi.mock("@/lib/callbacks", () => ({
  registerCallbacksForCompany,
  cleanupCallbacksForCompany,
  callbackStore: {
    findByTokenDigest: vi.fn(async () => null),
    upsert: vi.fn(async () => {}),
    deleteForInstallation,
  },
}));
vi.mock("@/lib/settings", () => ({
  dropletSettings: vi.fn(async () => ({
    name: "Template",
    embed_url: null,
    uuid: "drp_test",
    active: true,
  })),
}));
vi.mock("@/lib/config", () => ({
  dropletConfig: { webhooks: [] },
  registerAllFeatures: vi.fn(async () => ({
    webhooks: { success: 0, failed: 0, errors: [] },
  })),
  cleanupAllFeatures: vi.fn(async () => ({
    webhooks: { success: 0, failed: 0 },
  })),
}));

const { handleDropletInstalled } = await import("./droplet-installed");
const { handleDropletUninstalled } = await import("./droplet-uninstalled");

const installPayload = {
  company: {
    fluid_shop: "acme.fluid.app",
    name: "Acme",
    fluid_company_id: 42,
    droplet_uuid: "drp_test",
    droplet_installation_uuid: "dri_acme",
    authentication_token: "cat_acme",
    webhook_verification_token: "wvt_acme",
  },
};

beforeEach(() => {
  vi.clearAllMocks();
  mockPrisma.company.findFirst.mockResolvedValue(null);
  mockPrisma.company.create.mockResolvedValue(companyFixture());
  mockPrisma.company.update.mockResolvedValue(companyFixture());
  registerCallbacksForCompany.mockResolvedValue({
    success: 1,
    failed: 0,
    registeredUuids: ["cbr_1"],
    errors: [],
  });
});

describe("handleDropletInstalled", () => {
  it("creates the company and registers its active callbacks", async () => {
    await handleDropletInstalled(installPayload);

    expect(mockPrisma.company.create).toHaveBeenCalledOnce();
    const created = mockPrisma.company.create.mock.calls[0][0].data;
    expect(created.fluidShop).toBe("acme.fluid.app");
    // db/schema.rb types this bigint, and Rails wrote it as one.
    expect(created.fluidCompanyId).toBe(42n);
    expect(created.companyDropletUuid).toBe("drp_test");

    expect(registerCallbacksForCompany).toHaveBeenCalledWith(
      expect.anything(),
      "dri_acme",
    );
  });

  it("records the registered callback uuids on the company", async () => {
    await handleDropletInstalled(installPayload);

    const update = mockPrisma.company.update.mock.calls.at(-1)![0];
    expect(update.data.installedCallbackIds).toEqual(["cbr_1"]);
  });

  it("updates the existing row rather than duplicating it", async () => {
    mockPrisma.company.findFirst.mockResolvedValue(companyFixture());

    await handleDropletInstalled(installPayload);

    expect(mockPrisma.company.create).not.toHaveBeenCalled();
    expect(mockPrisma.company.update).toHaveBeenCalled();
  });

  it("clears uninstalled_at, so a reinstall is live again", async () => {
    mockPrisma.company.findFirst.mockResolvedValue(
      companyFixture({ uninstalledAt: new Date(), active: false }),
    );

    await handleDropletInstalled(installPayload);

    const update = mockPrisma.company.update.mock.calls[0][0];
    expect(update.data.uninstalledAt).toBeNull();
    expect(update.data.active).toBe(true);
  });

  it("prunes superseded digests only AFTER a clean registration", async () => {
    // Never before. Webhook delivery is at-least-once, so a redelivered
    // droplet.installed for a working installation used to delete the live
    // digest, then get 409 from createCallback because Fluid still held that
    // registration — leaving Fluid calling a registration whose token we no
    // longer had, and every one of those callbacks refused behind a 200.
    await handleDropletInstalled(installPayload);

    expect(deleteForInstallation).not.toHaveBeenCalled();
    expect(mockPrisma.fluidCallbackRegistration.deleteMany).toHaveBeenCalledWith({
      where: { dri: "dri_acme", uuid: { notIn: ["cbr_1"] } },
    });
  });

  it("keeps every stored digest when registration did not complete cleanly", async () => {
    // The failure is typically a 409 for a registration that is live, working,
    // and whose token we already hold. Deleting that row is exactly how a
    // healthy installation gets broken.
    registerCallbacksForCompany.mockResolvedValueOnce({
      success: 0,
      failed: 1,
      registeredUuids: [],
      // Contents do not matter here — `failed > 0` is what decides whether the
      // prune runs. In production this is a 409: the registration is already
      // live and working, and we still hold its token.
      errors: [],
    });

    await handleDropletInstalled(installPayload);

    expect(
      mockPrisma.fluidCallbackRegistration.deleteMany,
    ).not.toHaveBeenCalled();
    expect(deleteForInstallation).not.toHaveBeenCalled();
  });

  it("ignores an install event for a different droplet", async () => {
    await handleDropletInstalled({
      company: { ...installPayload.company, droplet_uuid: "drp_someone_else" },
    });

    expect(mockPrisma.company.create).not.toHaveBeenCalled();
    expect(registerCallbacksForCompany).not.toHaveBeenCalled();
  });

  it("rejects a payload with no authentication token", async () => {
    const { authentication_token: _omitted, ...rest } = installPayload.company;
    await expect(handleDropletInstalled({ company: rest })).rejects.toThrow();
  });
});

describe("handleDropletUninstalled", () => {
  it("deletes the recorded registrations and marks the row uninstalled", async () => {
    mockPrisma.company.findFirst.mockResolvedValue(
      companyFixture({ installedCallbackIds: ["cbr_1", "cbr_2"] }),
    );

    await handleDropletUninstalled({
      company: { fluid_company_id: 42, droplet_installation_uuid: "dri_acme" },
    });

    expect(cleanupCallbacksForCompany).toHaveBeenCalledWith(
      expect.anything(),
      1n,
      ["cbr_1", "cbr_2"],
      "dri_acme",
    );

    const update = mockPrisma.company.update.mock.calls.at(-1)![0];
    expect(update.data.active).toBe(false);
    expect(update.data.uninstalledAt).toBeInstanceOf(Date);
  });

  it("does nothing when no company matches", async () => {
    mockPrisma.company.findFirst.mockResolvedValue(null);

    await handleDropletUninstalled({
      company: { fluid_company_id: 999 },
    });

    expect(cleanupCallbacksForCompany).not.toHaveBeenCalled();
    expect(mockPrisma.company.update).not.toHaveBeenCalled();
  });
});

describe("payloadForHandler — the shape Fluid actually sent", () => {
  // Asserted on the FUNCTION the route calls, not on the handler. The previous
  // version of this test called the handler directly with an already-unwrapped
  // object, so it would have passed even if the route forwarded the wrong thing
  // entirely — which is the exact defect it was written to catch.
  const company = { fluid_shop: "acme", name: "Acme" };

  it("passes the inner object for the {name, payload} envelope", async () => {
    const { payloadForHandler } = await import("@/app/api/webhooks/route");
    expect(
      payloadForHandler({ name: "droplet_installed", payload: { company } }),
    ).toEqual({ company });
  });

  it("passes the inner object when the envelope nests resource/event", async () => {
    const { payloadForHandler } = await import("@/app/api/webhooks/route");
    expect(
      payloadForHandler({
        payload: { resource: "droplet", event: "installed", company },
      }),
    ).toEqual({ resource: "droplet", event: "installed", company });
  });

  it("keeps the ROOT object when resource/event are at the top level", async () => {
    // Even though a `payload` key is present. This is the case the first fix
    // broke: the SDK recognised the event from the root fields, so the root
    // object is the payload, and unwrapping would have handed the handler
    // `{metadata:{}}` and thrown.
    const { payloadForHandler } = await import("@/app/api/webhooks/route");
    const body = {
      resource: "droplet",
      event: "installed",
      company,
      payload: { metadata: {} },
    };
    expect(payloadForHandler(body)).toBe(body);
  });

  it("leaves anything it cannot classify alone", async () => {
    const { payloadForHandler } = await import("@/app/api/webhooks/route");
    const body = { company };
    expect(payloadForHandler(body)).toBe(body);
    expect(payloadForHandler(null)).toBeNull();
    expect(payloadForHandler([{ company }])).toEqual([{ company }]);
  });
});

describe("effectivePayload — agreement with the SDK's eventOf", () => {
  // These are the shapes eventOf accepts that a hand-written unwrap rule got
  // wrong. Both consumers — the tenant-hint reader and the handler — now take
  // the object eventOf derived the event from, so there is one rule rather than
  // two that drift.
  const company = { fluid_shop: "acme" };

  it("gives `name` precedence over a root resource/event pair, as eventOf does", async () => {
    const { payloadForHandler } = await import("@/app/api/webhooks/route");
    expect(
      payloadForHandler({
        name: "droplet_installed",
        resource: "ignored",
        event: "ignored",
        payload: { company },
      }),
    ).toEqual({ company });
  });

  it("follows eventOf's nested `event`-only fallback", async () => {
    const { payloadForHandler } = await import("@/app/api/webhooks/route");
    expect(
      payloadForHandler({ payload: { event: "droplet.installed", company } }),
    ).toEqual({ event: "droplet.installed", company });
  });
});
