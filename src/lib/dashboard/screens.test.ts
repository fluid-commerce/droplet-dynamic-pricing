/**
 * The three list/stat screens Rails served from PublicAdminController:
 * /admin/home, /admin/cart_pricing_events and /admin/transactions.
 */

import { describe, it, expect } from "vitest";

import { LIST_PER_PAGE, totalPages, listWindow } from "./screens";

describe("LIST_PER_PAGE", () => {
  it("is 50, not the dashboard's 10", () => {
    // The dashboard embed pages by 10; these full-page lists page by 50. Two
    // different numbers in two different controllers, both deliberate.
    expect(LIST_PER_PAGE).toBe(50);
  });
});

describe("totalPages", () => {
  it("rounds up, as `(total.to_f / per_page).ceil` did", () => {
    expect(totalPages(0, 50)).toBe(0);
    expect(totalPages(1, 50)).toBe(1);
    expect(totalPages(50, 50)).toBe(1);
    expect(totalPages(51, 50)).toBe(2);
  });
});

describe("listWindow", () => {
  it("offsets by page", () => {
    expect(listWindow(1)).toEqual({ take: 50, skip: 0 });
    expect(listWindow(3)).toEqual({ take: 50, skip: 100 });
  });

  it("never produces a negative skip", () => {
    // Rails did NOT clamp here: `@page = (params[:page] || 1).to_i` with no
    // `.max(1)`, so `?page=0` computed `offset(-50)` and Postgres refused the
    // query. Prisma throws on a negative `skip`, so the same input would be a
    // 500 either way. Clamped instead, matching the dashboard controller in
    // the same app, which DID clamp.
    expect(listWindow(0)).toEqual({ take: 50, skip: 0 });
    expect(listWindow(-3)).toEqual({ take: 50, skip: 0 });
  });
});
