/**
 * The backfill must never leave an installation with a partial set of digests.
 */

import { describe, it, expect, vi, beforeEach } from "vitest";
import { tokenDigest } from "@fluid-app/droplet-sdk";

const mockPrisma = vi.hoisted(() => ({
  $transaction: vi.fn(async (ops: unknown[]) => ops),
  fluidCallbackRegistration: {
    deleteMany: vi.fn((args: unknown) => ({ op: "deleteMany", args })),
    create: vi.fn((args: unknown) => ({ op: "create", args })),
    findUnique: vi.fn(),
    upsert: vi.fn(),
    count: vi.fn(),
  },
}));

vi.mock("@/lib/db", () => ({ prisma: mockPrisma, default: mockPrisma }));

const { backfillInstallation, stagingStore } = await import("./backfill");
type ClientLike = Parameters<typeof backfillInstallation>[0]["client"];

const DROPLET_URL = "https://droplet.test";
const OUR_URL = `${DROPLET_URL}/api/callbacks/cart-item-added`;

function listing(rows: unknown[]) {
  // The SDK pages until it sees an empty page or one that adds nothing new.
  let served = false;
  return {
    listCallbacks: vi.fn(async () => {
      if (served) return { callback_registrations: [] };
      served = true;
      return { callback_registrations: rows };
    }),
  };
}

beforeEach(() => {
  vi.clearAllMocks();
  mockPrisma.$transaction.mockImplementation(async (ops: unknown[]) => ops);
});

describe("backfillInstallation", () => {
  it("swaps in one transaction, deleting before inserting", async () => {
    const client = listing([
      {
        uuid: "cbr_1",
        definition_name: "cart_item_added",
        url: OUR_URL,
        verification_token: "cvt_live",
      },
    ]);

    const result = await backfillInstallation({
      client: client as unknown as ClientLike,
      dri: "dri_acme",
      dropletUrl: DROPLET_URL,
      ownUrls: [OUR_URL],
      enabledDefinitions: ["cart_item_added"],
    });

    expect(result.ok).toBe(true);
    expect(result.stored).toBe(1);

    // One transaction, delete first, then the inserts.
    expect(mockPrisma.$transaction).toHaveBeenCalledOnce();
    const ops = mockPrisma.$transaction.mock.calls[0][0] as Array<{
      op: string;
    }>;
    expect(ops.map((op) => op.op)).toEqual(["deleteMany", "create"]);

    const created = mockPrisma.fluidCallbackRegistration.create.mock
      .calls[0][0] as { data: Record<string, unknown> };
    expect(created.data.tokenDigest).toBe(tokenDigest("cvt_live"));
    expect(JSON.stringify(created.data)).not.toContain("cvt_live");
  });

  it("writes NOTHING when a definition has no token", async () => {
    // This is the property that matters. A partial swap would delete the
    // installation's working digests and replace them with an incomplete set,
    // so every callback for the missing definition would be refused — silently.
    const client = listing([
      {
        uuid: "cbr_1",
        definition_name: "cart_item_added",
        url: OUR_URL,
        verification_token: "cvt_live",
      },
    ]);

    const result = await backfillInstallation({
      client: client as unknown as ClientLike,
      dri: "dri_acme",
      dropletUrl: DROPLET_URL,
      ownUrls: [OUR_URL],
      enabledDefinitions: ["cart_item_added", "update_cart_tax"],
    });

    expect(result.ok).toBe(false);
    expect(result.missing).toEqual(["update_cart_tax"]);
    expect(mockPrisma.$transaction).not.toHaveBeenCalled();
    expect(mockPrisma.fluidCallbackRegistration.deleteMany).not.toHaveBeenCalled();
  });

  it("writes nothing when a registration came back without a token", async () => {
    const client = listing([
      { uuid: "cbr_1", definition_name: "cart_item_added", url: OUR_URL },
    ]);

    const result = await backfillInstallation({
      client: client as unknown as ClientLike,
      dri: "dri_acme",
      dropletUrl: DROPLET_URL,
      ownUrls: [OUR_URL],
      enabledDefinitions: ["cart_item_added"],
    });

    expect(result.ok).toBe(false);
    expect(mockPrisma.$transaction).not.toHaveBeenCalled();
  });

  it("does not adopt another droplet's registration on the same host", async () => {
    // The listing is COMPANY-scoped, so it contains every droplet's
    // registrations. Origin-only matching would accept this one, and its token
    // would then verify at our route.
    const client = listing([
      {
        uuid: "cbr_theirs",
        definition_name: "cart_item_added",
        url: `${DROPLET_URL}/api/not-a-route-we-serve`,
        verification_token: "cvt_theirs",
      },
    ]);

    const result = await backfillInstallation({
      client: client as unknown as ClientLike,
      dri: "dri_acme",
      dropletUrl: DROPLET_URL,
      ownUrls: [OUR_URL],
      enabledDefinitions: ["cart_item_added"],
    });

    expect(result.ok).toBe(false);
    expect(result.foreign).toBe(1);
    expect(mockPrisma.$transaction).not.toHaveBeenCalled();
  });

  it("asks Fluid for a full page rather than accepting the default of ten", async () => {
    const client = listing([
      {
        uuid: "cbr_1",
        definition_name: "cart_item_added",
        url: OUR_URL,
        verification_token: "cvt_live",
      },
    ]);

    await backfillInstallation({
      client: client as unknown as ClientLike,
      dri: "dri_acme",
      dropletUrl: DROPLET_URL,
      ownUrls: [OUR_URL],
      enabledDefinitions: ["cart_item_added"],
    });

    expect(client.listCallbacks).toHaveBeenCalledWith({
      page: 1,
      per_page: 100,
    });
  });
});

describe("stagingStore", () => {
  it("collects instead of writing, and never deletes", async () => {
    const collected: Array<{ uuid: string }> = [];
    const store = stagingStore(collected as never);

    await store.upsert({
      uuid: "cbr_1",
      dri: "dri_acme",
      definitionName: "cart_item_added",
      tokenDigest: "digest",
      url: OUR_URL,
    });
    await store.deleteForInstallation("dri_acme");

    expect(collected).toHaveLength(1);
    expect(mockPrisma.fluidCallbackRegistration.deleteMany).not.toHaveBeenCalled();
    // Nothing looks up by digest during a backfill.
    await expect(store.findByTokenDigest("digest")).resolves.toBeNull();
  });
});
