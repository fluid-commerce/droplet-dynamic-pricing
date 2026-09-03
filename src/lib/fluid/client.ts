/**
 * Fluid API Client
 *
 * Port of app/clients/fluid_client.rb and app/clients/fluid/*.rb.
 *
 * Two differences from the Ruby original, both deliberate:
 *
 *  - The Ruby client set its Authorization header via HTTParty's *class-level*
 *    `headers`, so constructing a second FluidClient mutated the first one's
 *    credentials. Here the token is per-instance.
 *  - `listCallbacks` forwards `{ page, per_page }`. Fluid's index action
 *    defaults to 10 per page and the endpoint is COMPANY-scoped, so a client
 *    that drops the params sees only the first ten of a company's
 *    registrations — including registrations owned by other droplets.
 *
 * Every endpoint used here is real. `/api/company/callbacks` is not, and is
 * not called: the callback endpoints live under `/api/callback/*`.
 */

import { z } from "zod";

export class FluidError extends Error {
  constructor(
    message: string,
    readonly status: number,
    readonly body: string,
  ) {
    super(message);
    this.name = "FluidError";
  }
}

export class FluidAuthenticationError extends FluidError {
  constructor(message: string, status: number, body: string) {
    super(message, status, body);
    this.name = "FluidAuthenticationError";
  }
}

export class FluidResourceNotFoundError extends FluidError {
  constructor(message: string, status: number, body: string) {
    super(message, status, body);
    this.name = "FluidResourceNotFoundError";
  }
}

const createWebhookSchema = z.object({
  resource: z.string(),
  url: z.string().url(),
  active: z.boolean().default(true),
  auth_token: z.string(),
  event: z.string(),
  http_method: z.enum(["post", "get", "put", "delete", "patch"]).default("post"),
});

export type CreateWebhookPayload = z.input<typeof createWebhookSchema>;

export const webhookSchema = z.object({
  id: z.union([z.number(), z.string()]),
  resource: z.string().optional(),
  event: z.string().optional(),
  url: z.string().optional(),
  active: z.boolean().optional(),
});

export type FluidWebhook = z.infer<typeof webhookSchema>;

const createCallbackRegistrationSchema = z.object({
  definition_name: z.string(),
  url: z.string().url(),
  timeout_in_seconds: z.number().int().positive().max(20).optional(),
  active: z.boolean().default(true),
});

export type CreateCallbackRegistrationPayload = z.input<
  typeof createCallbackRegistrationSchema
>;

export const callbackRegistrationSchema = z.object({
  uuid: z.string(),
  definition_name: z.string(),
  url: z.string(),
  active: z.boolean().optional(),
  /**
   * Returned by `api_create` and by `api_index` (via the blueprint's `shared`
   * view). NOT returned by update — `before_create :set_tokens` is the only
   * writer, so a token cannot be rotated in place.
   */
  verification_token: z.string().optional(),
  created_at: z.string().optional(),
  updated_at: z.string().optional(),
});

export type CallbackRegistration = z.infer<typeof callbackRegistrationSchema>;

export interface CallbackDefinition {
  name: string;
  description?: string;
  version?: string;
}

export interface DropletPayload {
  name?: string;
  embed_url?: string | null;
  uuid?: string;
  active?: boolean;
  settings?: Record<string, unknown>;
}

export class FluidClient {
  private readonly baseUrl: string;
  private readonly authToken: string;

  constructor(authToken: string, baseUrl?: string) {
    this.authToken = authToken;
    this.baseUrl = (
      baseUrl ||
      process.env.FLUID_API_URL ||
      "https://api.fluid.app"
    ).replace(/\/$/, "");
  }

  private async request<T>(path: string, options: RequestInit = {}): Promise<T> {
    const response = await fetch(`${this.baseUrl}${path}`, {
      ...options,
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${this.authToken}`,
        ...options.headers,
      },
    });

    if (!response.ok) {
      // The body is included because Fluid puts the validation errors there,
      // and never the request — which is where the credentials would be.
      const body = await response.text();
      const message = `Fluid API error: ${response.status} ${response.statusText}`;
      if (response.status === 401) {
        throw new FluidAuthenticationError(message, response.status, body);
      }
      if (response.status === 404) {
        throw new FluidResourceNotFoundError(message, response.status, body);
      }
      throw new FluidError(message, response.status, body);
    }

    if (response.status === 204) return undefined as T;

    const text = await response.text();
    return (text ? JSON.parse(text) : undefined) as T;
  }

  // --- Droplets -----------------------------------------------------------

  async getDroplet(uuid: string): Promise<{ droplet: DropletPayload }> {
    return this.request(`/api/droplets/${uuid}`);
  }

  async createDroplet(
    droplet: DropletPayload,
  ): Promise<{ droplet: DropletPayload }> {
    return this.request("/api/droplets", {
      method: "POST",
      body: JSON.stringify({ droplet }),
    });
  }

  async updateDroplet(
    uuid: string,
    droplet: DropletPayload,
  ): Promise<{ droplet: DropletPayload }> {
    return this.request(`/api/droplets/${uuid}`, {
      method: "PUT",
      body: JSON.stringify({ droplet }),
    });
  }

  async deleteDroplet(uuid: string): Promise<void> {
    return this.request(`/api/droplets/${uuid}`, { method: "DELETE" });
  }

  // --- Webhooks -----------------------------------------------------------

  async listWebhooks(): Promise<{ webhooks: FluidWebhook[] }> {
    return this.request("/api/company/webhooks");
  }

  async createWebhook(
    payload: CreateWebhookPayload,
  ): Promise<{ webhook: FluidWebhook }> {
    return this.request("/api/company/webhooks", {
      method: "POST",
      body: JSON.stringify({ webhook: createWebhookSchema.parse(payload) }),
    });
  }

  async updateWebhook(
    webhookId: string,
    payload: CreateWebhookPayload,
  ): Promise<{ webhook: FluidWebhook }> {
    return this.request(`/api/company/webhooks/${webhookId}`, {
      method: "PUT",
      body: JSON.stringify({ webhook: createWebhookSchema.parse(payload) }),
    });
  }

  async deleteWebhook(webhookId: string): Promise<void> {
    return this.request(`/api/company/webhooks/${webhookId}`, {
      method: "DELETE",
    });
  }

  // --- Callback definitions ------------------------------------------------

  /** GET /api/callback/definitions — the catalogue the admin UI syncs from. */
  async listCallbackDefinitions(): Promise<{
    definitions: CallbackDefinition[];
  }> {
    return this.request("/api/callback/definitions");
  }

  // --- Callback registrations ----------------------------------------------

  /**
   * GET /api/callback/registrations.
   *
   * `page` and `per_page` are forwarded rather than optional-in-name-only: the
   * endpoint defaults to 10 per page and is scoped to the company, not to this
   * droplet, so a caller that ignores paging silently adopts (or cleans up)
   * only the first ten rows of a list it does not own all of.
   */
  async listCallbacks(params?: {
    page?: number;
    per_page?: number;
    active?: boolean;
    definition_name?: string;
  }): Promise<{ callback_registrations: CallbackRegistration[] }> {
    const query = new URLSearchParams();
    if (params?.page) query.set("page", String(params.page));
    if (params?.per_page) query.set("per_page", String(params.per_page));
    if (params?.active !== undefined) query.set("active", String(params.active));
    if (params?.definition_name) {
      query.set("definition_name", params.definition_name);
    }
    const suffix = query.size > 0 ? `?${query}` : "";

    return this.request(`/api/callback/registrations${suffix}`);
  }

  /**
   * POST /api/callback/registrations.
   *
   * The response is the ONLY place `verification_token` is issued on a new
   * registration, so the caller must persist its digest here or delete the
   * registration again. See registerCallbacksForCompany.
   */
  async createCallback(
    payload: CreateCallbackRegistrationPayload,
  ): Promise<{ callback_registration: CallbackRegistration }> {
    return this.request("/api/callback/registrations", {
      method: "POST",
      body: JSON.stringify({
        callback_registration: createCallbackRegistrationSchema.parse(payload),
      }),
    });
  }

  async getCallback(
    uuid: string,
  ): Promise<{ callback_registration: CallbackRegistration }> {
    return this.request(`/api/callback/registrations/${uuid}`);
  }

  /**
   * PUT /api/callback/registrations/:uuid.
   *
   * Note that Fluid's update action accepts only definition_name, url and
   * active — it will not accept or return `verification_token`.
   */
  async updateCallback(
    uuid: string,
    payload: Partial<CreateCallbackRegistrationPayload>,
  ): Promise<{ callback_registration: CallbackRegistration }> {
    return this.request(`/api/callback/registrations/${uuid}`, {
      method: "PUT",
      body: JSON.stringify({ uuid, callback_registration: payload }),
    });
  }

  async deleteCallback(uuid: string): Promise<void> {
    return this.request(`/api/callback/registrations/${uuid}`, {
      method: "DELETE",
    });
  }

  // --- Carts ---------------------------------------------------------------
  //
  // Port of app/clients/fluid/carts.rb. These three are the writes that change
  // what a shopper pays and what a rep earns; everything in src/lib/pricing
  // exists to decide whether and with what to call them.

  /** PATCH /api/carts/:token/append_metadata — stamps `price_type` on a cart. */
  async appendCartMetadata(
    cartToken: string,
    metadata: Record<string, unknown>,
  ): Promise<unknown> {
    return this.request(`/api/carts/${cartToken}/append_metadata`, {
      method: "PATCH",
      body: JSON.stringify({ cart: { metadata } }),
    });
  }

  /**
   * PATCH /api/carts/:token/update_cart_items_prices.
   *
   * Fluid stamps `metadata.price_locked` on every line this writes and then
   * skips those lines when it reprices, which is why
   * CartCountryChangedService exists at all.
   */
  async updateCartItemsPrices(
    cartToken: string,
    items: Array<{ id: unknown; price: number }>,
  ): Promise<unknown> {
    return this.request(`/api/carts/${cartToken}/update_cart_items_prices`, {
      method: "PATCH",
      body: JSON.stringify({ cart_items: items }),
    });
  }

  /** PATCH /api/carts/:token/items/:id/update_volumes — CV/QV, i.e. commission. */
  async updateCartItemVolumes(
    cartToken: string,
    itemId: unknown,
    volumes: { cv: number; qv: number },
  ): Promise<unknown> {
    return this.request(
      `/api/carts/${cartToken}/items/${String(itemId)}/update_volumes`,
      { method: "PATCH", body: JSON.stringify(volumes) },
    );
  }

  // --- Customers -----------------------------------------------------------

  /**
   * GET /api/customers.
   *
   * The Ruby client mapped `email:` onto `search_query`, not onto an `email`
   * filter, and callers relied on that — `get_customer_id_by_email` takes the
   * FIRST result of a search. Kept exactly, because narrowing it here would
   * change which customer a cart resolves to.
   */
  async listCustomers(params: {
    email?: string;
    search_query?: string;
    page?: number;
    per_page?: number;
  }): Promise<{ customers?: Array<Record<string, unknown>> }> {
    const query = new URLSearchParams();
    if (params.page !== undefined) query.set("page", String(params.page));
    if (params.per_page !== undefined) {
      query.set("per_page", String(params.per_page));
    }
    if (params.search_query !== undefined) {
      query.set("search_query", params.search_query);
    }
    if (params.email !== undefined) query.set("search_query", params.email);
    const suffix = query.size > 0 ? `?${query}` : "";

    return this.request(`/api/customers${suffix}`);
  }

  async findCustomer(
    customerId: string | number,
  ): Promise<Record<string, unknown>> {
    return this.request(`/api/customers/${customerId}`);
  }

  async appendCustomerMetadata(
    customerId: string | number,
    metadata: Record<string, unknown>,
  ): Promise<unknown> {
    return this.request(`/api/customers/${customerId}/append_metadata`, {
      method: "PATCH",
      body: JSON.stringify({ metadata }),
    });
  }

  // --- Subscriptions -------------------------------------------------------

  async listSubscriptionsByCustomer(
    customerId: string | number,
    params: { status?: string; page?: number; per_page?: number } = {},
  ): Promise<Record<string, unknown>> {
    const query = new URLSearchParams();
    if (params.page !== undefined) query.set("page", String(params.page));
    if (params.per_page !== undefined) {
      query.set("per_page", String(params.per_page));
    }
    if (params.status !== undefined) query.set("status", params.status);
    query.set("customer_id", String(customerId));

    return this.request(`/api/subscriptions?${query}`);
  }

  // --- Variants ------------------------------------------------------------

  /**
   * GET /api/company/v1/variants/:id — the `variant_countries` rows the
   * cross-country price guard (STU2-3108) is built on.
   */
  async getVariant(
    variantId: string | number,
  ): Promise<Record<string, unknown>> {
    return this.request(`/api/company/v1/variants/${variantId}`);
  }

  // --- Metafields ----------------------------------------------------------

  async listMetafields(params: {
    resource_type: string;
    resource_id: string | number;
    page?: number;
    per_page?: number;
  }): Promise<{ metafields?: Array<Record<string, unknown>> }> {
    const query = new URLSearchParams({
      resource_type: String(params.resource_type),
      resource_id: String(params.resource_id),
      page: String(params.page ?? 1),
      per_page: String(params.per_page ?? 100),
    });
    return this.request(`/api/v2/metafields?${query}`);
  }

  async findMetafieldDefinition(params: {
    owner_resource: string;
    key: string;
    page?: number;
    per_page?: number;
  }): Promise<Record<string, unknown> | null> {
    const query = new URLSearchParams({
      owner_resource: String(params.owner_resource),
      search_query: String(params.key),
      page: String(params.page ?? 1),
      per_page: String(params.per_page ?? 50),
    });
    const response = await this.request<{
      metafield_definitions?: Array<Record<string, unknown>>;
    }>(`/api/v2/metafield_definitions?${query}`);

    return (
      (response.metafield_definitions ?? []).find(
        (definition) => definition["key"] === params.key,
      ) ?? null
    );
  }

  async createMetafieldDefinition(params: {
    namespace: string;
    key: string;
    value_type: string;
    description?: string;
    owner_resource?: string;
  }): Promise<unknown> {
    const definition: Record<string, unknown> = {
      namespace: params.namespace,
      key: params.key,
      name: params.key,
      value_type: params.value_type,
      owner_resource: params.owner_resource ?? "Customer",
      pinned: false,
      locked: false,
    };
    if (params.description) definition["description"] = params.description;

    return this.request("/api/v2/metafield_definitions", {
      method: "POST",
      body: JSON.stringify({ metafield_definition: definition }),
    });
  }

  async updateMetafield(payload: MetafieldWritePayload): Promise<unknown> {
    return this.request("/api/v2/metafields/update", {
      method: "PATCH",
      body: JSON.stringify(metafieldBody(payload)),
    });
  }

  async createMetafield(payload: MetafieldWritePayload): Promise<unknown> {
    return this.request("/api/v2/metafields", {
      method: "POST",
      body: JSON.stringify(metafieldBody(payload)),
    });
  }

  // --- Members -------------------------------------------------------------
  //
  // Port of app/clients/fluid/members.rb. Admin-tier endpoints that the
  // droplet's own installation token reaches (it sets company_admin and
  // auth_type "droplet", which skips the Tier-2 permission check).

  /**
   * GET /api/v2025-06/members/find.
   *
   * EXACTLY ONE identifier. Fluid does not AND them — it matches on the first
   * present key in `email, username, external_id, legacy_customer_id` order and
   * ignores the rest — so passing two would quietly resolve on the wrong one.
   */
  async findMemberBy(
    identifier: Partial<Record<MemberIdentifier, string | number>>,
  ): Promise<Record<string, unknown>> {
    const keys = Object.keys(identifier) as MemberIdentifier[];
    const unknownKeys = keys.filter((k) => !MEMBER_IDENTIFIERS.includes(k));
    if (unknownKeys.length > 0) {
      throw new Error(
        `unknown identifier ${unknownKeys.join(", ")}; expected one of ${MEMBER_IDENTIFIERS.join(", ")}`,
      );
    }
    if (keys.length !== 1) {
      throw new Error(
        `findMemberBy takes exactly one of ${MEMBER_IDENTIFIERS.join(", ")}, got ${keys.length}`,
      );
    }

    const query = new URLSearchParams({
      [keys[0]]: String(identifier[keys[0]]),
    });
    return this.request(`/api/v2025-06/members/find?${query}`);
  }

  async updateMemberType(
    memberId: string | number,
    slug: string,
  ): Promise<unknown> {
    return this.request(`/api/v2025-06/members/${memberId}/member-type`, {
      method: "PUT",
      body: JSON.stringify({ member_type_slug: slug }),
    });
  }
}

/**
 * Fluid provisions this system member type for every company
 * (Company::SystemMemberTypeProvisioner, tier_level 1), so it is a constant
 * rather than per-company config.
 */
export const PREFERRED_MEMBER_SLUG = "preferred";

export const MEMBER_IDENTIFIERS = [
  "email",
  "username",
  "external_id",
  "legacy_customer_id",
] as const;

export type MemberIdentifier = (typeof MEMBER_IDENTIFIERS)[number];

export interface MetafieldWritePayload {
  resource_type: string;
  resource_id: string | number;
  namespace: string;
  key: string;
  value: unknown;
  value_type: string;
  description?: string;
}

/**
 * The metafield write body.
 *
 * `value` is sent as-is for `value_type: "json"` and stringified otherwise,
 * matching app/clients/fluid/metafields.rb. A blank value is refused rather
 * than sent: Fluid answers `value cannot be blank`, and the Ruby raised
 * ArgumentError for the same reason.
 */
function metafieldBody(payload: MetafieldWritePayload): Record<string, unknown> {
  const blank =
    payload.value === null ||
    payload.value === undefined ||
    payload.value === "" ||
    (Array.isArray(payload.value) && payload.value.length === 0) ||
    (typeof payload.value === "object" &&
      payload.value !== null &&
      !Array.isArray(payload.value) &&
      Object.keys(payload.value).length === 0);
  if (blank) throw new Error("value cannot be blank");

  const body: Record<string, unknown> = {
    resource_type: String(payload.resource_type),
    resource_id: Number(payload.resource_id),
    namespace: String(payload.namespace),
    key: String(payload.key),
    value:
      payload.value_type === "json" ? payload.value : String(payload.value),
    value_type: String(payload.value_type),
  };
  if (payload.description) body["description"] = String(payload.description);
  return body;
}

export function createFluidClient(
  authToken: string,
  baseUrl?: string,
): FluidClient {
  return new FluidClient(authToken, baseUrl);
}
