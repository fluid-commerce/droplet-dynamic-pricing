/**
 * Per-company integration settings.
 *
 * Port of app/models/integration_setting.rb, which is not a schema — it is
 * eleven hand-written readers over two schemaless `jsonb` columns, each with a
 * default that exists nowhere in the database. Reading a key directly is
 * therefore always wrong; go through this module.
 *
 * Two Ruby behaviours that a naive port gets wrong, and both change pricing:
 *
 *  1. The boolean readers run the raw value through `ActiveModel::Type::Boolean`.
 *     That treats the STRINGS "0", "f", "false", "off" and "" as false and
 *     everything else present as true. A bare `Boolean(value)` in TypeScript
 *     gets `"false"` exactly backwards — and `yield_to_enrollment_wholesale`
 *     deciding "true" is a company silently handing every enrollment cart to
 *     another droplet.
 *  2. The two customer-type ids are STRINGS ("2"/"1") wherever they come from —
 *     the JSONB default and the admin form's text field — while Exigo returns
 *     `CustomerTypeID` as an integer. Comparisons must be string-vs-string
 *     (see `exigoCustomerTypeMatches`), never `2 === "2"`.
 */

import { castBoolean, isBlank, orDefault, toF, toI } from "@/lib/ruby";

/** Subscription CV/QV volume sources — see `subscriptionVolumeSource`. */
export const DEFAULT_SUBSCRIPTION_VOLUME_SOURCE = "price_ratio";
export const PREFERRED_CUSTOMER_VOLUME_SOURCE = "preferred_customer";

/** Preferred-status read sources — see `preferredSource`. */
export const DEFAULT_PREFERRED_SOURCE = "exigo";
export const FLUID_MEMBER_TYPE_PREFERRED_SOURCE = "fluid_member_type";

/** Exigo preferred signals — see `exigoPreferredSignal`. */
export const DEFAULT_EXIGO_PREFERRED_SIGNAL = "autoships";
export const CUSTOMER_TYPE_EXIGO_PREFERRED_SIGNAL = "customer_type";

export interface IntegrationSettingRow {
  enabled: boolean | null;
  settings: unknown;
  credentials: unknown;
}

export interface ExigoCredentials {
  dbHost: string;
  dbUsername: string;
  dbPassword: string;
  dbName: string;
  apiBaseUrl: string;
  apiUsername: string;
  apiPassword: string;
}

function asRecord(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : {};
}

/**
 * A read-only view over one `integration_settings` row.
 *
 * `null` — no row at all — is a valid input and yields every default, matching
 * Ruby's `company.integration_setting&.foo || default` chains.
 */
export class IntegrationSettings {
  private readonly settings: Record<string, unknown>;
  private readonly credentials: Record<string, unknown>;
  readonly enabled: boolean;

  constructor(row: IntegrationSettingRow | null) {
    this.settings = asRecord(row?.settings);
    this.credentials = asRecord(row?.credentials);
    this.enabled = row?.enabled === true;
  }

  static none(): IntegrationSettings {
    return new IntegrationSettings(null);
  }

  /** `exigo_enabled?` — the flag AND a complete set of credentials. */
  get exigoEnabled(): boolean {
    if (!this.enabled) return false;
    if (Object.keys(this.credentials).length === 0) return false;
    const c = this.exigoCredentials;
    return (
      !isBlank(c.dbHost) &&
      !isBlank(c.dbUsername) &&
      !isBlank(c.dbPassword) &&
      !isBlank(c.dbName) &&
      !isBlank(c.apiBaseUrl) &&
      !isBlank(c.apiUsername) &&
      !isBlank(c.apiPassword)
    );
  }

  /**
   * The seven plaintext credential keys.
   *
   * They are stored unencrypted in `integration_settings.credentials`, exactly
   * as Rails left them. This migration does not change that — encrypting them
   * is a separate decision on a separate PR — but nothing here may WIDEN the
   * exposure, so no route renders them and no log line prints them.
   */
  get exigoCredentials(): ExigoCredentials {
    const s = (key: string): string => {
      const value = this.credentials[key];
      return typeof value === "string" ? value : value == null ? "" : String(value);
    };
    return {
      dbHost: s("exigo_db_host"),
      dbUsername: s("exigo_db_username"),
      dbPassword: s("exigo_db_password"),
      dbName: s("exigo_db_name"),
      apiBaseUrl: s("api_base_url"),
      apiUsername: s("api_username"),
      apiPassword: s("api_password"),
    };
  }

  /**
   * `yield_to_enrollment_wholesale?` — dynamic pricing no-ops on BP enrollment
   * carts so yoli-promos' wholesale pricing wins (STU2-2377). Off by default:
   * for every company that does NOT run yoli-promos, yielding would strip
   * preferred-customer pricing from enrollment carts.
   */
  get yieldToEnrollmentWholesale(): boolean {
    return castBoolean(this.settings["yield_to_enrollment_wholesale"]);
  }

  /** `adjust_volumes_for_subscription?` (STU2-2526). Off by default. */
  get adjustVolumesForSubscription(): boolean {
    return castBoolean(this.settings["adjust_volumes_for_subscription"]);
  }

  /** `promote_member_type_on_first_subscription?`. Off by default. */
  get promoteMemberTypeOnFirstSubscription(): boolean {
    return castBoolean(
      this.settings["promote_member_type_on_first_subscription"],
    );
  }

  /**
   * "price_ratio" (default — retail volumes scaled by the subscription
   * discount) or "preferred_customer" (the catalog's pc_cv/pc_qv written
   * directly, for companies whose retail volumes differ from the correct
   * subscription ones).
   */
  get subscriptionVolumeSource(): string {
    return orDefault(
      this.settings["subscription_volume_source"],
      DEFAULT_SUBSCRIPTION_VOLUME_SOURCE,
    );
  }

  get preferredSource(): string {
    return orDefault(this.settings["preferred_source"], DEFAULT_PREFERRED_SOURCE);
  }

  /**
   * Asked rather than compared at each call site, so an UNRECOGNISED value
   * cannot quietly take a tenant off its working source — the setting that
   * would stop a company reading Exigo is the one that must fail safe.
   */
  get preferredFromFluidMemberType(): boolean {
    return this.preferredSource === FLUID_MEMBER_TYPE_PREFERRED_SOURCE;
  }

  get exigoPreferredSignal(): string {
    return orDefault(
      this.settings["exigo_preferred_signal"],
      DEFAULT_EXIGO_PREFERRED_SIGNAL,
    );
  }

  /** Same fail-safe shape as `preferredFromFluidMemberType`. */
  get exigoPreferredByCustomerType(): boolean {
    return this.exigoPreferredSignal === CUSTOMER_TYPE_EXIGO_PREFERRED_SIGNAL;
  }

  /** String, not number — see the header note. Ruby default is `"2"`. */
  get preferredCustomerTypeId(): string {
    return orDefault(this.settings["preferred_customer_type_id"], "2");
  }

  /** String, not number. Ruby default is `"1"`. */
  get retailCustomerTypeId(): string {
    return orDefault(this.settings["retail_customer_type_id"], "1");
  }

  /**
   * Ruby: `settings.dig(...)&.to_f || 0.5`.
   *
   * `&.` is the ONLY thing that reaches the default: a stored `0` becomes
   * `0.0`, which is truthy in Ruby, so zero delay stays zero delay. A
   * `parsed === 0 ? default : parsed` port would silently reintroduce a
   * half-second sleep per customer on an installation that had turned it off.
   */
  get apiDelaySeconds(): number {
    const value = this.settings["api_delay_seconds"];
    return value === null || value === undefined ? 0.5 : toF(value);
  }

  /** Ruby: `settings.dig(...)&.to_i || 5`. Same zero-is-truthy note as above. */
  get snapshotsToKeep(): number {
    const value = this.settings["snapshots_to_keep"];
    return value === null || value === undefined ? 5 : toI(value);
  }

  /** Ruby: `settings.dig(...)&.to_i || 10_000`. */
  get dailyWarmupLimit(): number {
    const value = this.settings["daily_warmup_limit"];
    return value === null || value === undefined ? 10_000 : toI(value);
  }
}
