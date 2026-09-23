/**
 * The dropzone dashboard's data layer.
 *
 * Port of DynamicPricingDashboardController#index. The pagination rule is the
 * subtle part: only the ACTIVE tab is offset. The inactive one always shows its
 * first page, because its own `?page=` would otherwise be applied to both lists
 * and paging one would silently scroll the other.
 */

import { describe, it, expect } from "vitest";

import { maskEmail, resolveTab, resolvePage, pageWindow } from "./query";

describe("maskEmail", () => {
  it("keeps the first two characters and masks the rest of the local part", () => {
    expect(maskEmail("matias@fluid.app")).toBe("ma****@fluid.app");
  });

  it("leaves a local part of two characters or fewer untouched", () => {
    expect(maskEmail("ab@x.com")).toBe("ab@x.com");
  });

  it("does not mask the domain", () => {
    expect(maskEmail("someone@verylongdomain.example")).toBe(
      "so*****@verylongdomain.example",
    );
  });

  it("returns null for a blank email, as `email_safe` did", () => {
    expect(maskEmail(null)).toBeNull();
    expect(maskEmail("")).toBeNull();
    expect(maskEmail("   ")).toBeNull();
  });
});

describe("resolveTab", () => {
  it("accepts the two allowed tabs", () => {
    expect(resolveTab("cart_events")).toBe("cart_events");
    expect(resolveTab("transactions")).toBe("transactions");
  });

  it("falls back to cart_events for anything else", () => {
    // ALLOWED_TABS in Rails. The value lands in a query the page runs, so an
    // unrecognised tab must resolve to a known one rather than be passed on.
    expect(resolveTab("'; drop table--")).toBe("cart_events");
    expect(resolveTab(undefined)).toBe("cart_events");
  });
});

describe("resolvePage", () => {
  it("defaults to 1", () => {
    expect(resolvePage(undefined)).toBe(1);
  });

  it("clamps below 1, matching `[params[:page].to_i, 1].max`", () => {
    expect(resolvePage("0")).toBe(1);
    expect(resolvePage("-5")).toBe(1);
  });

  it("reads a non-numeric page as 1, the way `to_i` does", () => {
    expect(resolvePage("banana")).toBe(1);
  });

  it("accepts a real page", () => {
    expect(resolvePage("3")).toBe(3);
  });
});

describe("pageWindow", () => {
  it("offsets only the active list", () => {
    expect(pageWindow("cart_events", 3, 10)).toEqual({
      cartEvents: { take: 10, skip: 20 },
      transactions: { take: 10, skip: 0 },
    });

    expect(pageWindow("transactions", 3, 10)).toEqual({
      cartEvents: { take: 10, skip: 0 },
      transactions: { take: 10, skip: 20 },
    });
  });

  it("offsets nothing on page 1", () => {
    expect(pageWindow("cart_events", 1, 10)).toEqual({
      cartEvents: { take: 10, skip: 0 },
      transactions: { take: 10, skip: 0 },
    });
  });
});
