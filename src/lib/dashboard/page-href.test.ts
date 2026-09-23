/**
 * Paging links across the server/client boundary.
 *
 * The tabs are `"use client"`. Handing them `hrefForPage={(page) => ...}` works
 * from `dashboard.tsx`, which is itself a client component — the closure never
 * crosses a boundary. It does NOT work from `/admin/transactions` or
 * `/admin/cart_pricing_events`, which are server components: React cannot
 * serialize a function, and both pages answered 500.
 *
 * A template is serializable, so the same prop works from either side.
 */

import { describe, it, expect } from "vitest";

import { pageHref, PAGE_PLACEHOLDER } from "./page-href";

describe("pageHref", () => {
  it("substitutes the page number", () => {
    expect(
      pageHref(`/admin/transactions?dri=abc&page=${PAGE_PLACEHOLDER}`, 3),
    ).toBe("/admin/transactions?dri=abc&page=3");
  });

  it("substitutes every occurrence", () => {
    expect(pageHref(`/x?a=${PAGE_PLACEHOLDER}&b=${PAGE_PLACEHOLDER}`, 7)).toBe(
      "/x?a=7&b=7",
    );
  });

  it("leaves a template with no placeholder alone", () => {
    expect(pageHref("/admin/transactions", 4)).toBe("/admin/transactions");
  });

  it("uses a placeholder no URL-encoded value can contain", () => {
    // It travels through URLSearchParams on the way in, so it has to survive
    // encoding unchanged or the substitution silently misses.
    expect(new URLSearchParams({ page: PAGE_PLACEHOLDER }).toString()).toBe(
      `page=${PAGE_PLACEHOLDER}`,
    );
  });
});
