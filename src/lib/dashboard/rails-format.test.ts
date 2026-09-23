/**
 * Pinned to what Ruby printed, so the ported tables show the strings the Rails
 * screens did.
 */

import { describe, it, expect } from "vitest";

import {
  humanize,
  numberWithPrecision2,
  railsDate,
  railsTime,
} from "./rails-format";

describe("railsDate — strftime('%b %d, %Y') in UTC", () => {
  it("zero-pads the day", () => {
    expect(railsDate("2026-09-03T17:05:00Z")).toBe("Sep 03, 2026");
  });

  it("reads the UTC date, not the local one", () => {
    expect(railsDate("2026-12-31T23:30:00Z")).toBe("Dec 31, 2026");
  });
});

describe("railsTime — strftime('%I:%M %p') in UTC", () => {
  it.each([
    ["2026-09-03T00:05:00Z", "12:05 AM"],
    ["2026-09-03T09:07:00Z", "09:07 AM"],
    ["2026-09-03T12:00:00Z", "12:00 PM"],
    ["2026-09-03T17:30:00Z", "05:30 PM"],
  ])("%s -> %s", (iso, expected) => {
    expect(railsTime(iso)).toBe(expected);
  });
});

describe("humanize — ActiveSupport String#humanize", () => {
  it.each([
    ["preferred_customer", "Preferred customer"],
    ["webhook", "Webhook"],
    ["cart_country_changed", "Cart country changed"],
    ["customer_id", "Customer"],
    ["EXIGO_SYNC", "Exigo sync"],
  ])("%s -> %s", (input, expected) => {
    expect(humanize(input)).toBe(expected);
  });

  it("renders nothing for a missing value instead of raising", () => {
    expect(humanize(null)).toBe("");
  });
});

describe("numberWithPrecision2 — number_with_precision(x, precision: 2)", () => {
  it.each([
    ["123.4", "123.40"],
    ["10", "10.00"],
    ["1.005", "1.01"],
    ["2499.995", "2500.00"],
    ["0.004", "0.00"],
    ["1234567.891", "1234567.89"],
  ])("%s -> %s", (input, expected) => {
    expect(numberWithPrecision2(input)).toBe(expected);
  });
});
