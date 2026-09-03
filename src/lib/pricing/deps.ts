/**
 * Everything the pricing engine talks to, behind one interface.
 *
 * The Ruby reached straight for `FluidClient`, `ExigoClient`, `Rails.cache`,
 * `Rails.logger`, `Sentry` and `CartPricingEvent.create!` from inside the
 * pricing logic. That is why its tests had to stub HTTP.
 *
 * Naming the seam does two useful things. A test can assert the exact SEQUENCE
 * of Fluid calls a payload produces — which is the property that actually
 * matters here, because "the shopper was charged the wrong amount" is a wrong
 * call with the right response body. And §3.3 of the migration plan asks for
 * call COUNTS to be watched during cutover, which needs a place to count them.
 */

import { PREFERRED_MEMBER_SLUG, type FluidClient } from "@/lib/fluid";
import { FluidResourceNotFoundError } from "@/lib/fluid/client";
import { IntegrationSettings } from "@/lib/integration-settings";
import type { ExigoReader } from "@/lib/exigo/client";
import type { Json, PricedItem, Volumes } from "./types";

export interface PricingLogger {
  info(message: string): void;
  warn(message: string): void;
  error(message: string): void;
}

/**
 * The preferred-status lookup cache.
 *
 * Rails used `Rails.cache`, which in this app is Solid Cache in a SEPARATE
 * Postgres database — shared across every process. The Next app drops Solid
 * Cache (see the migration plan §6), so this is per-container instead.
 *
 * That is a real behaviour change and it is the safe direction: the cache only
 * ever suppresses a repeat lookup within a 30-second window, so a cold
 * container spends the extra Fluid/Exigo call rather than getting a wrong
 * answer. The burst it exists for — one cart_item callback per line of a
 * multi-line add — arrives on one container in practice.
 */
export interface PreferredLookupCache {
  digest(value: string): string;
  read(key: string): boolean | undefined;
  write(key: string, value: boolean, ttlSeconds: number): void;
}

/** The Fluid surface the pricing engine uses, and nothing wider. */
export interface PricingFluidApi {
  appendCartMetadata(
    cartToken: string,
    metadata: Record<string, unknown>,
  ): Promise<unknown>;
  updateCartItemsPrices(
    cartToken: string,
    items: PricedItem[],
  ): Promise<unknown>;
  updateCartItemVolumes(
    cartToken: string,
    itemId: unknown,
    volumes: Volumes,
  ): Promise<unknown>;
  listCustomers(params: {
    email: string;
  }): Promise<{ customers?: Array<Record<string, unknown>> }>;
  listSubscriptionsByCustomer(
    customerId: string,
    params: { status?: string },
  ): Promise<Record<string, unknown>>;
  getVariant(variantId: string): Promise<Record<string, unknown>>;
  getMetafieldByKey(params: {
    resource_type: string;
    resource_id: string;
    key: string;
  }): Promise<Json | null>;
  ensureMetafieldDefinition(params: {
    namespace: string;
    key: string;
    value_type: string;
    description?: string;
    owner_resource?: string;
  }): Promise<unknown>;
  updateMetafield(payload: MetafieldWrite): Promise<unknown>;
  createMetafield(payload: MetafieldWrite): Promise<unknown>;
  /** `member_type_slug` for exactly one identifier, or undefined. */
  readMemberTypeSlug(
    identifier: Record<string, string | number>,
  ): Promise<unknown>;
  /** Whether an error from any of the above is Fluid's 404. */
  isNotFound(error: unknown): boolean;
}

export interface MetafieldWrite {
  resource_type: string;
  resource_id: number;
  namespace: string;
  key: string;
  value: unknown;
  value_type: string;
  description?: string;
}

export interface CartPricingEventInput {
  companyId: bigint;
  cartId: unknown;
  email: unknown;
  eventType: string;
  preferredPricingApplied: boolean;
  itemsCount: number;
  cartTotal: number;
  metadata: Record<string, unknown>;
}

export interface PricingDeps {
  company: { id: bigint; name: string };
  settings: IntegrationSettings;
  fluid: PricingFluidApi;
  /** null when the company has no usable Exigo configuration. */
  exigo: ExigoReader | null;
  cache: PreferredLookupCache;
  log: PricingLogger;
  preferredMemberSlug: string;
  recordCartPricingEvent(input: CartPricingEventInput): Promise<void>;
  reportException(error: unknown, context: Record<string, unknown>): void;
}

/**
 * Adapts the real `FluidClient` to `PricingFluidApi`.
 *
 * `ensureMetafieldDefinition` is composed here rather than on the client
 * because it is two calls with an error rule: Fluid answers "already exists" /
 * "duplicate" for a definition another process created a moment earlier, and
 * that is success, not failure.
 */
export function pricingFluidApi(client: FluidClient): PricingFluidApi {
  return {
    appendCartMetadata: (token, metadata) =>
      client.appendCartMetadata(token, metadata),
    updateCartItemsPrices: (token, items) =>
      client.updateCartItemsPrices(token, items),
    updateCartItemVolumes: (token, itemId, volumes) =>
      client.updateCartItemVolumes(token, itemId, volumes),
    listCustomers: (params) => client.listCustomers(params),
    listSubscriptionsByCustomer: (customerId, params) =>
      client.listSubscriptionsByCustomer(customerId, params),
    getVariant: (variantId) => client.getVariant(variantId),

    async getMetafieldByKey({ resource_type, resource_id, key }) {
      const response = await client.listMetafields({
        resource_type,
        resource_id,
      });
      return (
        (response.metafields ?? []).find((m) => m["key"] === key) ?? null
      );
    },

    async ensureMetafieldDefinition(params) {
      const existing = await client.findMetafieldDefinition({
        owner_resource: params.owner_resource ?? "Customer",
        key: params.key,
      });
      if (existing) return existing;

      try {
        return await client.createMetafieldDefinition(params);
      } catch (error) {
        const message = (
          error instanceof Error ? error.message : String(error)
        ).toLowerCase();
        const body =
          error instanceof FluidResourceNotFoundError ||
          (error as { body?: string })?.body
            ? String((error as { body?: string }).body ?? "").toLowerCase()
            : "";
        if (
          message.includes("already") ||
          message.includes("duplicate") ||
          body.includes("already") ||
          body.includes("duplicate")
        ) {
          return undefined;
        }
        throw error;
      }
    },

    updateMetafield: (payload) => client.updateMetafield(payload),
    createMetafield: (payload) => client.createMetafield(payload),

    async readMemberTypeSlug(identifier) {
      const response = await client.findMemberBy(identifier);
      const member = response["member"];
      if (!member || typeof member !== "object") return undefined;
      return (member as Record<string, unknown>)["member_type_slug"];
    },

    isNotFound: (error) => error instanceof FluidResourceNotFoundError,
  };
}

export { PREFERRED_MEMBER_SLUG };
