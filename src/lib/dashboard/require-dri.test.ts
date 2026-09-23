/**
 * Uninstalling has to revoke the `dri`.
 *
 * Every screen in this droplet authenticates on a droplet installation UUID.
 * It is a lookup key, not a credential: it rides in a query string, so it
 * reaches browser history, referrers and anyone the merchant shares a link
 * with. The one thing that must hold is that it stops working when the
 * installation does — otherwise a `dri` captured once is good forever, and on
 * this droplet it gates writes to the global `Setting` and `Callback` rows.
 *
 * `droplet-uninstalled.ts` writes `active: false`, so that is the signal being
 * honoured here, and `not: false` rather than `true` is deliberate: `active` is
 * nullable with a `false` default, and a legacy row whose column was never
 * backfilled belongs to a company that is perfectly fine.
 */

import { describe, it, expect, vi, beforeEach } from "vitest";

const { mockPrisma } = vi.hoisted(() => ({
  mockPrisma: { company: { findFirst: vi.fn() } },
}));
vi.mock("@/lib/db", () => ({ prisma: mockPrisma }));

import { driIsInstalled, withDri } from "./require-dri";

describe("driIsInstalled", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mockPrisma.company.findFirst.mockResolvedValue({ id: 1n });
  });

  it("refuses a missing dri without asking the database", async () => {
    expect(await driIsInstalled(undefined)).toBe(false);
    expect(await driIsInstalled("")).toBe(false);
    expect(mockPrisma.company.findFirst).not.toHaveBeenCalled();
  });

  it("asks only for an installation uninstall has not deactivated", async () => {
    await driIsInstalled("dri_acme");

    // The filter is the whole point, so it is asserted rather than the result:
    // a stub returning a row would pass whatever the query said.
    expect(mockPrisma.company.findFirst).toHaveBeenCalledWith(
      expect.objectContaining({
        where: { dropletInstallationUuid: "dri_acme", active: { not: false } },
      }),
    );
  });

  it("accepts a dri the query matched", async () => {
    expect(await driIsInstalled("dri_acme")).toBe(true);
  });

  it("refuses a dri the query did not match", async () => {
    mockPrisma.company.findFirst.mockResolvedValue(null);

    expect(await driIsInstalled("dri_uninstalled")).toBe(false);
  });
});

describe("withDri", () => {
  it("carries the dri onto the next request", () => {
    expect(withDri("/admin/callbacks", "dri_acme")).toBe(
      "/admin/callbacks?dri=dri_acme",
    );
  });

  it("keeps extra params alongside it", () => {
    expect(withDri("/admin/callbacks", "dri_acme", { notice: "Saved" })).toBe(
      "/admin/callbacks?dri=dri_acme&notice=Saved",
    );
  });

  it("encodes rather than concatenating", () => {
    expect(withDri("/admin/callbacks", "dri_acme", { alert: "a b&c" })).toBe(
      "/admin/callbacks?dri=dri_acme&alert=a+b%26c",
    );
  });

  it("returns a bare path when there is no dri and nothing to add", () => {
    expect(withDri("/admin/callbacks", undefined)).toBe("/admin/callbacks");
  });
});
