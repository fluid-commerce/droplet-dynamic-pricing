/**
 * A recording harness for the pricing engine.
 *
 * The property that matters for this droplet is not the response body — Fluid
 * discards eight of the nine — it is the SEQUENCE of writes a payload produces.
 * "The shopper was charged the wrong amount" is a wrong `update_cart_items_prices`
 * with a perfectly valid `{success: true}` on top of it.
 *
 * So `recordingDeps` captures every Fluid call in order, with its arguments,
 * and the tests assert on that. It also captures call COUNTS, which is what
 * §3.3 of the migration plan asks to be watched during cutover: eight of these
 * callbacks sit on the shopper's request thread inside a 20-second ceiling.
 */

import { vi } from "vitest";

import { IntegrationSettings } from "@/lib/integration-settings";
import { MemoryPreferredLookupCache } from "@/lib/pricing/cache";
import type { PricingDeps, PricingFluidApi } from "@/lib/pricing/deps";
import type { Json } from "@/lib/pricing/types";

export interface RecordedCall {
  method: string;
  args: unknown[];
}

export interface FluidStubs {
  /** variantId -> the `variant_countries` rows to answer with. */
  variants?: Record<string, Json[]>;
  /** variantId -> throw instead of answering. */
  variantErrors?: string[];
  customers?: Array<Record<string, unknown>>;
  subscriptions?: Record<string, unknown>;
  metafield?: Json | null;
  memberTypeSlug?: unknown;
}

export interface RecordingDeps extends PricingDeps {
  calls: RecordedCall[];
  events: Array<Record<string, unknown>>;
  reported: Array<{ error: unknown; context: Record<string, unknown> }>;
  logs: { info: string[]; warn: string[]; error: string[] };
  /** Every call to one method, in order. */
  callsTo(method: string): RecordedCall[];
}

export function recordingDeps(options: {
  settings?: Record<string, unknown>;
  credentials?: Record<string, unknown>;
  enabled?: boolean;
  fluid?: FluidStubs;
  exigo?: Partial<PricingDeps["exigo"]> | null;
} = {}): RecordingDeps {
  const calls: RecordedCall[] = [];
  const events: Array<Record<string, unknown>> = [];
  const reported: Array<{ error: unknown; context: Record<string, unknown> }> =
    [];
  const logs = { info: [] as string[], warn: [] as string[], error: [] as string[] };
  const stubs = options.fluid ?? {};

  const record = (method: string, ...args: unknown[]) => {
    calls.push({ method, args });
  };

  const fluid: PricingFluidApi = {
    async appendCartMetadata(token, metadata) {
      record("appendCartMetadata", token, metadata);
      return {};
    },
    async updateCartItemsPrices(token, items) {
      record("updateCartItemsPrices", token, items);
      return {};
    },
    async updateCartItemVolumes(token, itemId, volumes) {
      record("updateCartItemVolumes", token, itemId, volumes);
      return {};
    },
    async listCustomers(params) {
      record("listCustomers", params);
      return { customers: stubs.customers ?? [] };
    },
    async listSubscriptionsByCustomer(customerId, params) {
      record("listSubscriptionsByCustomer", customerId, params);
      return stubs.subscriptions ?? { subscriptions: [] };
    },
    async getVariant(variantId) {
      record("getVariant", variantId);
      if (stubs.variantErrors?.includes(variantId)) {
        throw new Error(`variant ${variantId} unavailable`);
      }
      return {
        variant: { variant_countries: stubs.variants?.[variantId] ?? [] },
      };
    },
    async getMetafieldByKey(params) {
      record("getMetafieldByKey", params);
      return stubs.metafield ?? null;
    },
    async ensureMetafieldDefinition(params) {
      record("ensureMetafieldDefinition", params);
      return {};
    },
    async updateMetafield(payload) {
      record("updateMetafield", payload);
      return {};
    },
    async createMetafield(payload) {
      record("createMetafield", payload);
      return {};
    },
    async readMemberTypeSlug(identifier) {
      record("readMemberTypeSlug", identifier);
      return stubs.memberTypeSlug;
    },
    isNotFound: (error) =>
      error instanceof Error && error.name === "FluidResourceNotFoundError",
  };

  const deps: RecordingDeps = {
    company: { id: 1n, name: "Acme" },
    settings: new IntegrationSettings({
      enabled: options.enabled ?? false,
      settings: options.settings ?? {},
      credentials: options.credentials ?? {},
    }),
    fluid,
    exigo: (options.exigo ?? null) as PricingDeps["exigo"],
    cache: new MemoryPreferredLookupCache(),
    preferredMemberSlug: "preferred",
    log: {
      info: (m) => logs.info.push(m),
      warn: (m) => logs.warn.push(m),
      error: (m) => logs.error.push(m),
    },
    async recordCartPricingEvent(input) {
      record("recordCartPricingEvent", input);
      events.push(input as unknown as Record<string, unknown>);
    },
    reportException(error, context) {
      reported.push({ error, context });
    },
    calls,
    events,
    reported,
    logs,
    callsTo: (method) => calls.filter((call) => call.method === method),
  };

  return deps;
}

/** An Exigo reader whose answers are fixed. */
export function exigoStub(
  answers: {
    autoshipByEmail?: boolean | Error;
    customerTypeByEmail?: number | string | null;
    autoship?: boolean;
  } = {},
) {
  return {
    customerHasActiveAutoshipByEmail: vi.fn(async () => {
      if (answers.autoshipByEmail instanceof Error) {
        throw answers.autoshipByEmail;
      }
      return answers.autoshipByEmail ?? false;
    }),
    customerTypeByEmail: vi.fn(async () => answers.customerTypeByEmail ?? null),
    customerHasActiveAutoship: vi.fn(async () => answers.autoship ?? false),
    customersWithActiveAutoships: vi.fn(async () => []),
    customersByTypeId: vi.fn(async () => []),
    getCustomerType: vi.fn(async () => null),
    findCustomerIdByEmail: vi.fn(async () => null),
  };
}

/** A minimal but realistic cart payload. */
export function cartPayload(overrides: Partial<Json> = {}): Json {
  return {
    cart_token: "crt_1",
    company: { id: 42 },
    id: 7,
    email: "shopper@example.com",
    country_code: "US",
    items: [],
    metadata: {},
    ...overrides,
  };
}
