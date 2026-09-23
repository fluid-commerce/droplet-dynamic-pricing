/**
 * Price types.
 *
 * Port of PriceTypesController plus PriceTypeUseCases::Update / ::Delete. The
 * guard is the whole point: a price type in use by any customer cannot be
 * renamed or deleted, because the name IS the link — customers carry it in
 * `metadata.customer_type`, so renaming one orphans every customer pointing at
 * it and deleting one leaves them pointing at nothing.
 */

import { describe, it, expect, vi, beforeEach } from "vitest";

import { assertNotInUse } from "./price-types";

beforeEach(() => vi.clearAllMocks());

describe("assertNotInUse", () => {
  it("allows the change when no customer carries the name", async () => {
    const listCustomers = vi.fn(async () => ({ customers: [] }));

    await expect(
      assertNotInUse("Wholesale", listCustomers),
    ).resolves.toBeNull();

    expect(listCustomers).toHaveBeenCalledWith({
      by_metadata: { customer_type: "Wholesale" },
      per_page: 1,
    });
  });

  it("refuses when at least one customer carries the name", async () => {
    const listCustomers = vi.fn(async () => ({ customers: [{ id: 1 }] }));

    await expect(assertNotInUse("Wholesale", listCustomers)).resolves.toBe(
      "it is in use by one or more customers",
    );
  });

  it("asks for only ONE customer, not the whole page", async () => {
    // `per_page: 1`. The question is "does any exist", and this runs against a
    // live Fluid tenant from a form submit.
    const listCustomers = vi.fn(
      async (_params: {
        by_metadata: { customer_type: string };
        per_page: number;
      }) => ({ customers: [] as unknown[] }),
    );

    await assertNotInUse("Retail", listCustomers);

    expect(listCustomers.mock.calls[0][0]).toMatchObject({ per_page: 1 });
  });

  it("FAILS CLOSED when Fluid cannot answer", async () => {
    // Rails rescued FluidClient::Error into a failure, not into a pass. An
    // unreachable Fluid must not read as "nobody is using it" — that would let
    // an outage delete a price type every customer depends on.
    const listCustomers = vi.fn(async () => {
      throw new Error("502 Bad Gateway");
    });

    await expect(assertNotInUse("Wholesale", listCustomers)).resolves.toBe(
      "Failed to check customer usage: 502 Bad Gateway",
    );
  });

  it("treats a response with no customers key as empty, not as a failure", async () => {
    // Ruby: `response["customers"] || []`.
    const listCustomers = vi.fn(async () => ({}));

    await expect(
      assertNotInUse("Wholesale", listCustomers),
    ).resolves.toBeNull();
  });
});

describe("resolveDri", () => {
  it("prefers the query parameter and returns it for storing", async () => {
    const { resolveDri } = await import("./price-types");

    expect(resolveDri("dri_from_url", "dri_from_cookie")).toEqual({
      dri: "dri_from_url",
      store: true,
    });
  });

  it("falls back to the stored one when the URL carries none", async () => {
    // `store_dri_in_session`. /price_types and /customers link to each other
    // WITHOUT re-appending ?dri=, so after the first request the cookie is the
    // only thing keeping the tenant. The other dropzone screens do not do this.
    const { resolveDri } = await import("./price-types");

    expect(resolveDri(undefined, "dri_from_cookie")).toEqual({
      dri: "dri_from_cookie",
      store: false,
    });
  });

  it("has no tenant when neither is present", async () => {
    const { resolveDri } = await import("./price-types");

    expect(resolveDri(undefined, undefined)).toEqual({
      dri: null,
      store: false,
    });
  });

  it("ignores a blank query parameter rather than storing it", async () => {
    // `dri.present?` is false for "" in Ruby, so an empty ?dri= fell through to
    // the session instead of overwriting it with nothing.
    const { resolveDri } = await import("./price-types");

    expect(resolveDri("", "dri_from_cookie")).toEqual({
      dri: "dri_from_cookie",
      store: false,
    });
  });
});
