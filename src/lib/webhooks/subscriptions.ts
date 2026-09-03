/**
 * The five subscription webhook handlers.
 *
 * Port of `app/services/webhooks/base_service.rb` and its five subclasses.
 * These do NOT price carts — they move a customer between the
 * `preferred_customer` and `retail` customer_type, which is the value the
 * callback path later reads as a cached signal.
 *
 * Two events promote (`started`, `resumed`, `reactivated`), two conditionally
 * demote (`paused`, `cancelled`), and the condition is the whole subtlety:
 * `shouldRemainPreferred` asks whether ANOTHER subscription or an Exigo
 * autoship still stands, so cancelling one of two subscriptions does not cost
 * the shopper their pricing.
 *
 * ## The Exigo write is ported DEAD
 *
 * `updateExigoCustomerType` computes the target type id and then logs
 * `[EXIGO UPDATE DISABLED]` instead of writing, exactly as Rails does. Both
 * call sites there are commented out. Turning it on is a product decision, not
 * a side effect of a migration.
 */

import type { Company } from "@prisma/client";

import { prisma } from "@/lib/db";
import { createFluidClient, PREFERRED_MEMBER_SLUG } from "@/lib/fluid";
import { FluidResourceNotFoundError } from "@/lib/fluid/client";
import { field, isBlank, isPresent, toI } from "@/lib/ruby";
import { ExigoClient, type ExigoReader } from "@/lib/exigo/client";
import { IntegrationSettings } from "@/lib/integration-settings";
import { loadIntegrationSettings } from "@/lib/pricing/runtime";
import { pricingFluidApi, type PricingFluidApi } from "@/lib/pricing/deps";

export const PREFERRED_CUSTOMER_TYPE = "preferred_customer";
export const RETAIL_CUSTOMER_TYPE = "retail";

const METAFIELD_DESCRIPTION =
  "Customer type for pricing (preferred_customer, retail, null)";

export interface WebhookResult {
  success: boolean;
  message?: string;
  error?: string;
}

export interface SubscriptionWebhookDeps {
  company: Company;
  settings: IntegrationSettings;
  fluid: PricingFluidApi;
  exigo: ExigoReader | null;
  recordTransaction(input: {
    companyId: bigint;
    customerId: unknown;
    externalId: unknown;
    previousType: unknown;
    newType: string;
    source: string;
    metadata: Record<string, unknown>;
  }): Promise<void>;
  /** Raw client, for the two endpoints outside the pricing surface. */
  findCustomer(customerId: unknown): Promise<Record<string, unknown>>;
  appendCustomerMetadata(
    customerId: unknown,
    metadata: Record<string, unknown>,
  ): Promise<unknown>;
  updateMemberType(memberId: unknown, slug: string): Promise<unknown>;
  findMemberBy(
    identifier: Record<string, string | number>,
  ): Promise<Record<string, unknown>>;
}

export async function buildSubscriptionWebhookDeps(
  company: Company,
): Promise<SubscriptionWebhookDeps> {
  const settings = await loadIntegrationSettings(company.id);
  const client = createFluidClient(company.authenticationToken);

  return {
    company,
    settings,
    fluid: pricingFluidApi(client),
    exigo: settings.exigoEnabled
      ? new ExigoClient(settings.exigoCredentials, company.name)
      : null,
    async recordTransaction(input) {
      await prisma.customerTypeTransaction.create({
        data: {
          companyId: input.companyId,
          customerId: asInt32(input.customerId),
          externalId: asString(input.externalId),
          previousType: asString(input.previousType),
          newType: input.newType,
          source: input.source,
          metadata: input.metadata as never,
        },
      });
    },
    findCustomer: (customerId) => client.findCustomer(String(customerId)),
    appendCustomerMetadata: (customerId, metadata) =>
      client.appendCustomerMetadata(String(customerId), metadata),
    updateMemberType: (memberId, slug) =>
      client.updateMemberType(String(memberId), slug),
    findMemberBy: (identifier) => client.findMemberBy(identifier),
  };
}

/** The event names this module serves, and what each one does. */
export type SubscriptionEvent =
  | "started"
  | "resumed"
  | "reactivated"
  | "paused"
  | "cancelled";

export async function handleSubscriptionWebhook(
  event: SubscriptionEvent,
  payload: unknown,
  deps: SubscriptionWebhookDeps,
): Promise<WebhookResult> {
  try {
    const customerId = customerIdOf(payload);
    if (isBlank(customerId)) {
      return { success: false, error: "Customer ID not found in webhook params" };
    }

    if (event === "started" || event === "resumed" || event === "reactivated") {
      await setCustomerPreferred(customerId, payload, deps);
      return {
        success: true,
        message: `Subscription ${event} webhook processed successfully`,
      };
    }

    const subscriptionId = field(
      field<Record<string, unknown>>(payload, "subscription"),
      "id",
    );
    if (await shouldRemainPreferred(customerId, subscriptionId, payload, deps)) {
      return {
        success: true,
        message:
          "Customer has other subscriptions or Exigo autoship, no action taken",
      };
    }

    await setCustomerType(customerId, RETAIL_CUSTOMER_TYPE, payload, deps);
    return {
      success: true,
      message: `Subscription ${event} webhook processed successfully`,
    };
  } catch (error) {
    console.error(
      `Error processing subscription_${event} webhook: ${describe(error)}`,
    );
    return { success: false, error: describe(error) };
  }
}

/**
 * The customer id, from any of the six shapes Rails looked in.
 *
 * The list is not tidy and is kept as-is: each entry is a real payload shape
 * that reached production, and dropping one silently turns a promotion into a
 * "Customer ID not found".
 */
export function customerIdOf(payload: unknown): unknown {
  const root = payload as Record<string, unknown> | undefined;
  const subscription = field<Record<string, unknown>>(root, "subscription");
  const nested = field<Record<string, unknown>>(root, "payload");

  return (
    field(field<Record<string, unknown>>(subscription, "customer"), "id") ??
    field(
      field<Record<string, unknown>>(
        field<Record<string, unknown>>(nested, "subscription"),
        "customer",
      ),
      "id",
    ) ??
    field(field<Record<string, unknown>>(nested, "customer"), "id")
  );
}

function customerExternalIdFromPayload(payload: unknown): unknown {
  return field(
    field<Record<string, unknown>>(
      field<Record<string, unknown>>(payload, "subscription"),
      "customer",
    ),
    "external_id",
  );
}

/**
 * Promotion.
 *
 * `promoteMemberTypeToPreferred` runs BEFORE `setCustomerType`, not inside it:
 * that method returns early when the customer_type metafield already says
 * preferred, and seeding member types through the droplet is exactly the case
 * where the metafield is already right and the member type is not.
 */
async function setCustomerPreferred(
  customerId: unknown,
  payload: unknown,
  deps: SubscriptionWebhookDeps,
): Promise<void> {
  await promoteMemberTypeToPreferred(customerId, deps);
  await setCustomerType(customerId, PREFERRED_CUSTOMER_TYPE, payload, deps);
}

/**
 * Writes Fluid's own member type on the customer's first subscription, for
 * installations that opt in. Idempotent on its OWN read rather than on the
 * metafield, since the two can legitimately disagree while a company is seeding
 * member types.
 *
 * Swallows its failures: the metafield write behind it is the path that still
 * has to happen, and a member that cannot be resolved must not take the webhook
 * down.
 */
async function promoteMemberTypeToPreferred(
  customerId: unknown,
  deps: SubscriptionWebhookDeps,
): Promise<void> {
  try {
    if (!deps.settings.promoteMemberTypeOnFirstSubscription) return;
    if (isBlank(customerId)) return;

    const response = await deps.findMemberBy({
      legacy_customer_id: String(customerId),
    });
    const member = field<Record<string, unknown>>(response, "member");
    if (isBlank(member)) return;

    if (field(member, "member_type_slug") === PREFERRED_MEMBER_SLUG) {
      console.log(
        `Member for customer ${String(customerId)} is already preferred, skipping promotion`,
      );
      return;
    }

    const memberId = field(member, "id");
    if (isBlank(memberId)) return;

    await deps.updateMemberType(memberId, PREFERRED_MEMBER_SLUG);
    console.log(
      `Promoted member ${String(memberId)} (customer ${String(customerId)}) to preferred`,
    );
  } catch (error) {
    console.error(
      `Failed to promote member type for customer ${String(customerId)}: ${describe(error)}`,
    );
  }
}

async function setCustomerType(
  customerId: unknown,
  customerType: string,
  payload: unknown,
  deps: SubscriptionWebhookDeps,
): Promise<void> {
  const externalId = await customerExternalId(customerId, payload, deps);
  const previousType = await getCurrentCustomerType(customerId, deps);

  if (previousType === customerType) {
    console.log(
      `Customer ${String(customerId)} already has type '${customerType}', skipping update`,
    );
    return;
  }

  await updateCustomerTypeMetafield(customerId, customerType, deps);
  await updateCustomerMetadata(customerId, customerType, deps);
  await updateExigoCustomerType(externalId, customerType, deps);

  try {
    await deps.recordTransaction({
      companyId: deps.company.id,
      customerId,
      externalId,
      previousType,
      newType: customerType,
      source: "webhook",
      metadata: { webhook_params: slicePayload(payload) },
    });
  } catch (error) {
    console.error(`Failed to log customer type transaction: ${describe(error)}`);
  }
}

async function updateCustomerTypeMetafield(
  customerId: unknown,
  customerType: string,
  deps: SubscriptionWebhookDeps,
): Promise<void> {
  if (isBlank(customerType)) {
    console.error("customer_type is blank, cannot update metafield");
    throw new Error("customer_type cannot be blank");
  }

  const jsonValue = { customer_type: String(customerType) };

  await deps.fluid.ensureMetafieldDefinition({
    namespace: "custom",
    key: "customer_type",
    value_type: "json",
    description: METAFIELD_DESCRIPTION,
    owner_resource: "Customer",
  });

  try {
    await deps.fluid.updateMetafield({
      resource_type: "customer",
      resource_id: toI(customerId),
      namespace: "custom",
      key: "customer_type",
      value: jsonValue,
      value_type: "json",
      description: METAFIELD_DESCRIPTION,
    });
  } catch (error) {
    if (!(error instanceof FluidResourceNotFoundError)) throw error;
    console.warn(
      `Metafield not found for customer ${String(customerId)}; attempting create (${describe(error)})`,
    );
    await deps.fluid.createMetafield({
      resource_type: "customer",
      resource_id: toI(customerId),
      namespace: "custom",
      key: "customer_type",
      value: jsonValue,
      value_type: "json",
      description: METAFIELD_DESCRIPTION,
    });
  }
}

async function updateCustomerMetadata(
  customerId: unknown,
  customerType: string,
  deps: SubscriptionWebhookDeps,
): Promise<void> {
  try {
    await deps.appendCustomerMetadata(customerId, {
      customer_type: customerType,
    });
  } catch (error) {
    console.error(
      `Failed to update customer metadata for customer ${String(customerId)}: ${describe(error)}`,
    );
  }
}

/**
 * The Exigo write — DEAD, on purpose.
 *
 * It still performs the READ (`getCustomerType`) and the comparison, because
 * that is what Rails does and removing it would change the call pattern against
 * a client's SQL Server. Only the write is replaced by the log line.
 */
async function updateExigoCustomerType(
  externalId: unknown,
  customerType: string,
  deps: SubscriptionWebhookDeps,
): Promise<void> {
  try {
    if (!deps.settings.exigoEnabled || deps.exigo === null) return;
    if (isBlank(externalId)) return;

    const typeId = toI(
      customerType === PREFERRED_CUSTOMER_TYPE
        ? deps.settings.preferredCustomerTypeId
        : deps.settings.retailCustomerTypeId,
    );
    const currentTypeId = await deps.exigo.getCustomerType(String(externalId));
    if (currentTypeId === typeId) return;

    // COMMENTED FOR LOCAL TESTING in Rails — kept disabled here for the same
    // reason. See the module header.
    console.log(
      `[EXIGO UPDATE DISABLED] Would update customer ${String(externalId)} to type ${typeId}`,
    );
  } catch (error) {
    console.error(
      `Failed to update Exigo customer type for external ID ${String(externalId)}: ${describe(error)}`,
    );
  }
}

async function customerExternalId(
  customerId: unknown,
  payload: unknown,
  deps: SubscriptionWebhookDeps,
): Promise<unknown> {
  const fromPayload = customerExternalIdFromPayload(payload);
  if (isPresent(fromPayload)) return fromPayload;

  try {
    const customer = await deps.findCustomer(customerId);
    return field(customer, "external_id");
  } catch {
    return null;
  }
}

async function getCurrentCustomerType(
  customerId: unknown,
  deps: SubscriptionWebhookDeps,
): Promise<unknown> {
  try {
    const metafield = await deps.fluid.getMetafieldByKey({
      resource_type: "customer",
      resource_id: String(customerId),
      key: "customer_type",
    });
    const value = field(
      field<Record<string, unknown>>(metafield ?? undefined, "value"),
      "customer_type",
    );
    if (isPresent(value)) return value;

    const customer = await deps.findCustomer(customerId);
    return field(
      field<Record<string, unknown>>(customer, "metadata"),
      "customer_type",
    );
  } catch (error) {
    console.warn(
      `Failed to get current customer type for ${String(customerId)}: ${describe(error)}`,
    );
    return null;
  }
}

/**
 * Whether a pause or cancel should leave the customer preferred.
 *
 * The promotion toggle makes preferred PERMANENT: a company that promotes on
 * first subscription never demotes, so cancel and pause stop asking. Answered
 * before the live signals so no Fluid or Exigo call is spent on a question
 * whose answer cannot change.
 */
async function shouldRemainPreferred(
  customerId: unknown,
  excludeSubscriptionId: unknown,
  payload: unknown,
  deps: SubscriptionWebhookDeps,
): Promise<boolean> {
  if (deps.settings.promoteMemberTypeOnFirstSubscription) return true;

  if (await hasOtherActiveSubscriptions(customerId, excludeSubscriptionId, deps)) {
    return true;
  }

  const externalId = await customerExternalId(customerId, payload, deps);
  return hasExigoAutoship(externalId, deps);
}

async function hasOtherActiveSubscriptions(
  customerId: unknown,
  excludeSubscriptionId: unknown,
  deps: SubscriptionWebhookDeps,
): Promise<boolean> {
  try {
    const response = await deps.fluid.listSubscriptionsByCustomer(
      String(customerId),
      { status: "active" },
    );
    const raw = field(response, "subscriptions");
    let subscriptions = Array.isArray(raw) ? raw : [];

    if (isPresent(excludeSubscriptionId)) {
      const excluded = toI(excludeSubscriptionId);
      subscriptions = subscriptions.filter(
        (sub) => toI(field(sub as Record<string, unknown>, "id")) !== excluded,
      );
    }

    return subscriptions.length > 0;
  } catch {
    return false;
  }
}

async function hasExigoAutoship(
  externalId: unknown,
  deps: SubscriptionWebhookDeps,
): Promise<boolean> {
  try {
    if (!deps.settings.exigoEnabled || deps.exigo === null) return false;
    if (isBlank(externalId)) return false;
    return await deps.exigo.customerHasActiveAutoship(String(externalId));
  } catch {
    return false;
  }
}

/** Rails: `@webhook_params&.slice("subscription", "event_name")`. */
function slicePayload(payload: unknown): Record<string, unknown> {
  const record = payload as Record<string, unknown> | undefined;
  const out: Record<string, unknown> = {};
  if (record && "subscription" in record) out.subscription = record.subscription;
  if (record && "event_name" in record) out.event_name = record.event_name;
  return out;
}

function describe(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function asInt32(value: unknown): number | null {
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) return null;
  const truncated = Math.trunc(parsed);
  if (truncated > 2147483647 || truncated < -2147483648) return null;
  return truncated;
}

function asString(value: unknown): string | null {
  return typeof value === "string" ? value : value == null ? null : String(value);
}
