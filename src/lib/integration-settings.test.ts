/**
 * `integration_settings` is two schemaless jsonb columns with eleven in-code
 * defaults, so the reader is the schema. These are the places where the
 * obvious TypeScript is wrong about what Rails did.
 */

import { describe, it, expect } from "vitest";

import {
  IntegrationSettings,
  DEFAULT_SUBSCRIPTION_VOLUME_SOURCE,
} from "./integration-settings";

const of = (settings: Record<string, unknown>) =>
  new IntegrationSettings({ enabled: true, settings, credentials: {} });

describe("boolean readers use ActiveModel::Type::Boolean", () => {
  it.each([
    [true, true],
    ["true", true],
    ["1", true],
    [1, true],
    ["t", true],
    ["yes", true],
    [false, false],
    ["false", false],
    ["FALSE", false],
    ["0", false],
    [0, false],
    ["f", false],
    ["off", false],
    ["", false],
    [null, false],
    [undefined, false],
  ])("casts %o to %s", (value, expected) => {
    expect(of({ yield_to_enrollment_wholesale: value }).yieldToEnrollmentWholesale).toBe(
      expected,
    );
  });

  it('gets the string "false" right, which `Boolean(value)` does not', () => {
    // The one that matters: `Boolean("false")` is true in JavaScript. A company
    // that turned this OFF through the admin form would have every enrollment
    // cart handed to a droplet it may not even run.
    expect(Boolean("false")).toBe(true);
    expect(of({ adjust_volumes_for_subscription: "false" }).adjustVolumesForSubscription).toBe(
      false,
    );
  });
});

describe("string readers use Ruby's `||`, not blank-coalescing", () => {
  it("falls back only on nil", () => {
    expect(of({}).subscriptionVolumeSource).toBe(
      DEFAULT_SUBSCRIPTION_VOLUME_SOURCE,
    );
    expect(of({ subscription_volume_source: "preferred_customer" }).subscriptionVolumeSource).toBe(
      "preferred_customer",
    );
  });

  it("keeps an empty string, because it is truthy in Ruby", () => {
    // `"" || "price_ratio"` is `""` in Ruby. Every call site compares against a
    // known slug, so `""` and the default behave identically — but reproducing
    // the truthiness keeps that true rather than nearly true.
    expect(of({ subscription_volume_source: "" }).subscriptionVolumeSource).toBe("");
  });
});

describe("the source toggles are asked, never compared, so an unknown value fails safe", () => {
  it("keeps reading Exigo when preferred_source is a typo", () => {
    // The setting that would take a tenant OFF its working source is the one
    // that must fail safe.
    expect(of({ preferred_source: "fluid_membertype" }).preferredFromFluidMemberType).toBe(
      false,
    );
    expect(of({ preferred_source: "fluid_member_type" }).preferredFromFluidMemberType).toBe(
      true,
    );
  });

  it("keeps the autoship signal when exigo_preferred_signal is a typo", () => {
    expect(of({ exigo_preferred_signal: "customertype" }).exigoPreferredByCustomerType).toBe(
      false,
    );
    expect(of({ exigo_preferred_signal: "customer_type" }).exigoPreferredByCustomerType).toBe(
      true,
    );
  });
});

describe("numeric readers: zero is truthy in Ruby, so it is a real value", () => {
  it("returns the default only when the key is absent", () => {
    expect(of({}).apiDelaySeconds).toBe(0.5);
    expect(of({}).snapshotsToKeep).toBe(5);
    expect(of({}).dailyWarmupLimit).toBe(10_000);
  });

  it("keeps a stored 0 rather than reverting to the default", () => {
    // `0&.to_f || 0.5` is 0.0 in Ruby. A `parsed === 0 ? default : parsed` port
    // would silently reintroduce a half-second sleep per customer on an
    // installation that had turned it off.
    expect(of({ api_delay_seconds: 0 }).apiDelaySeconds).toBe(0);
    expect(of({ snapshots_to_keep: 0 }).snapshotsToKeep).toBe(0);
  });

  it("parses a numeric string the way Ruby's to_f/to_i do", () => {
    expect(of({ api_delay_seconds: "1.5" }).apiDelaySeconds).toBe(1.5);
    expect(of({ snapshots_to_keep: "7.9" }).snapshotsToKeep).toBe(7);
    // Ruby's to_f takes the leading numeric prefix; Number() would give NaN.
    expect(of({ api_delay_seconds: "2abc" }).apiDelaySeconds).toBe(2);
  });
});

describe("customer type ids are strings on both sides", () => {
  it("defaults to the string forms Rails used", () => {
    expect(of({}).preferredCustomerTypeId).toBe("2");
    expect(of({}).retailCustomerTypeId).toBe("1");
  });

  it("stringifies a number stored in JSONB, so `2 === '2'` never happens", () => {
    // Exigo returns CustomerTypeID as an integer; the admin form writes text.
    // Comparing them raw is false for every customer.
    expect(of({ preferred_customer_type_id: 2 }).preferredCustomerTypeId).toBe("2");
  });
});

describe("exigoEnabled", () => {
  const credentials = {
    exigo_db_host: "h",
    exigo_db_username: "u",
    exigo_db_password: "p",
    exigo_db_name: "d",
    api_base_url: "https://api",
    api_username: "au",
    api_password: "ap",
  };

  it("needs the flag AND a complete credential set", () => {
    expect(
      new IntegrationSettings({ enabled: true, settings: {}, credentials }).exigoEnabled,
    ).toBe(true);
    expect(
      new IntegrationSettings({ enabled: false, settings: {}, credentials }).exigoEnabled,
    ).toBe(false);
    expect(
      new IntegrationSettings({
        enabled: true,
        settings: {},
        credentials: { ...credentials, api_password: "" },
      }).exigoEnabled,
    ).toBe(false);
  });

  it("is false for a company with no integration_settings row at all", () => {
    expect(IntegrationSettings.none().exigoEnabled).toBe(false);
  });
});
