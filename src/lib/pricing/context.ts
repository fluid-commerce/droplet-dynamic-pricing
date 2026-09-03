/**
 * The pricing engine's shared state and decisions.
 *
 * Port of `app/services/callbacks/base_service.rb` — 1,124 lines whose comments
 * read like an incident log, because they are one. Every guard in here traces
 * to a ticket, and the ticket numbers are kept: they are the only record of why
 * an apparently redundant check is not redundant.
 *
 * The Ruby was a base class the nine services inherited. Here it is a context
 * object the nine service functions are given, which changes nothing about the
 * behaviour and makes the seam between "decide" and "write" visible: every
 * Fluid write goes through `deps.fluid`, so a test can assert the exact
 * sequence of calls a payload produces, not just the response body.
 *
 * The load-bearing rules, each of which must survive verbatim:
 *
 *  - the settled-cart denylist and `refuseSettledWrite` (CURRENT-3361)
 *  - `preferredLookupFailed` — "unknown" must NEVER be read as "not preferred"
 *  - `countrySafePrice` / `refuseCrossCountryPrice` (STU2-3108 — a PH cart was
 *    charged the CAD figure, 113.85 instead of 2,499)
 *  - the zero-price guard in `updateCartItemsPrices`
 *  - `bundlePriced` — never read variant_country for a bundle
 *  - `lockedCartItems` — only lines carrying `metadata.price_locked`
 *  - both `subscription_volume_source` modes (STU2-2526 / STU2-2531)
 *  - the yield to the BP wholesale droplet (STU2-2377 / STU2-2964)
 */

import { field, isBlank, isPresent, toF, toI } from "@/lib/ruby";
import {
  IntegrationSettings,
  PREFERRED_CUSTOMER_VOLUME_SOURCE,
} from "@/lib/integration-settings";
import type { PricingDeps } from "./deps";
import {
  CallbackError,
  CrossCountryPriceError,
  POST_ORDER_TRIGGERS,
  PREFERRED_CUSTOMER_TYPE,
  SETTLED_CART_STATES,
  type CallbackParams,
  type CallbackResult,
  type Json,
  type PricedItem,
  type VariantBaseVolumes,
  type Volumes,
} from "./types";

/**
 * Every column a price can come from. Which one Fluid used depends on the cart
 * and the item — a rep moves it to the wholesale columns, an unsubscribable
 * item collapses subscription onto regular, a zero discount falls back to the
 * base.
 */
const PRICE_COLUMNS = [
  "price",
  "subscription_price",
  "wholesale",
  "wholesale_subscription_price",
];

/**
 * How long one answer about a customer's standing subscriptions is reused.
 *
 * Core fires one cart_item callback per line, so an N-line add asks the same
 * two questions N times within a few seconds — each a round trip to Fluid or,
 * worse, a fresh SQL connection to Exigo, all inside the budget the shopper is
 * waiting on.
 *
 * Deliberately short. The cart-side half of the rule
 * (`hasAnotherSubscriptionInCart`) is read from the payload and never cached,
 * so the case where the shopper's own action changes the answer is still
 * answered live.
 */
export const PREFERRED_LOOKUP_TTL = toI(
  process.env.PREFERRED_LOOKUP_TTL_SECONDS ?? 30,
);

export class PricingContext {
  private readonly variantCountryRowsCache = new Map<string, Json[] | null>();
  private readonly customerTypeMetafieldCache = new Map<string, unknown>();
  private readonly memberPreferredCache = new Map<string, boolean>();
  private preferredLookupFailure = false;

  constructor(
    readonly params: CallbackParams,
    readonly deps: PricingDeps,
  ) {}

  // --- Payload accessors ---------------------------------------------------

  get cart(): Json | undefined {
    return this.params.cart;
  }

  get cartToken(): string | undefined {
    const value = field(this.cart, "cart_token");
    return typeof value === "string" ? value : undefined;
  }

  get customerEmail(): string | undefined {
    const value = field(this.cart, "email");
    return typeof value === "string" && value.length > 0 ? value : undefined;
  }

  get cartCustomerId(): unknown {
    return field(this.cart, "customer_id");
  }

  get customerLoggedIn(): boolean {
    return isPresent(this.cartCustomerId);
  }

  get cartItems(): Json[] {
    const items = field(this.cart, "items");
    return Array.isArray(items) ? (items.filter(isObject) as Json[]) : [];
  }

  /** The single cart item carried by item_added / item_updated callbacks. */
  get cartItem(): Json | undefined {
    return this.params.cart_item;
  }

  /**
   * Every item this callback speaks for. A company on Fluid's
   * BATCH_CART_ITEM_CALLBACKS flag sends one `cart_item_added` per add
   * operation with the added items in `cart_items` (first element identical to
   * `cart_item`); everyone else sends `cart_item` alone.
   */
  get callbackCartItems(): Json[] {
    const batch = this.params.cart_items;
    if (Array.isArray(batch) && batch.length > 0) {
      return batch.filter(isObject) as Json[];
    }
    return this.cartItem ? [this.cartItem] : [];
  }

  /** `context` is a top-level sibling of `cart`, not a cart field. */
  get callbackContext(): Json {
    return this.params.context ?? {};
  }

  get callbackTriggerSource(): unknown {
    return field(this.callbackContext, "trigger_source");
  }

  get cartState(): unknown {
    return field(this.cart, "state");
  }

  get currentPriceType(): unknown {
    return field(field<Json>(this.cart, "metadata"), "price_type");
  }

  // --- Guards --------------------------------------------------------------

  /**
   * True when this callback must not write to the cart at all. TWO independent
   * signals, because the incident needed both: the order_completion attach
   * still reported a mutable-looking cart on one payload, and the logout detach
   * that followed it reported payment_captured (CURRENT-3361).
   *
   * Note this keys off cart STATE, not the trigger: a logout while the shopper
   * is still building the cart is a legitimate reason to revert pricing and
   * must keep working.
   */
  get cartSettled(): boolean {
    return (
      SETTLED_CART_STATES.includes(String(this.cartState)) ||
      POST_ORDER_TRIGGERS.includes(String(this.callbackTriggerSource))
    );
  }

  /**
   * Last line of defence for the settled-cart guard. The services return early
   * on `cartSettled`, but enforcing it at every write means a service that
   * forgets to — or a path added later — still cannot charge-then-reprice.
   */
  private refuseSettledWrite(what: string): boolean {
    if (!this.cartSettled) return false;

    this.deps.log.warn(
      `[DynamicPricing] Refusing to write ${what} to settled cart ${this.cartToken} ` +
        `(state=${JSON.stringify(this.cartState)}, trigger=${JSON.stringify(this.callbackTriggerSource)})`,
    );
    return true;
  }

  /**
   * BP enrollment carts are priced by the yoli-promos droplet (wholesale),
   * which takes precedence (STU2-2377). Gated behind a per-company toggle, off
   * by default: for everyone who does not run yoli-promos, yielding would strip
   * preferred-customer pricing from enrollment carts.
   */
  get yieldToEnrollmentWholesale(): boolean {
    return this.enrollmentCart && this.settings.yieldToEnrollmentWholesale;
  }

  private get enrollmentCart(): boolean {
    if (field(this.cart, "type") === "enrollment") return true;
    return this.cartItems.some((item) =>
      isPresent(field(item, "enrollment_pack_id")),
    );
  }

  /**
   * yoli-promos stamps `cart.metadata.price_type = "wholesale"` when its
   * WHOLESALE unlock code is applied (bp_wholesale_applied, STU2-2964). Dynamic
   * pricing yields on that cart too — and NOT behind the per-company toggle:
   * any cart stamped this way is explicitly under yoli-promos' wholesale
   * pricing.
   */
  get priceTypeWholesale(): boolean {
    return this.currentPriceType === "wholesale";
  }

  /** Both the enrollment and the metadata yield, as the services ask it. */
  get yieldsToWholesaleDroplet(): boolean {
    return this.yieldToEnrollmentWholesale || this.priceTypeWholesale;
  }

  get settings(): IntegrationSettings {
    return this.deps.settings;
  }

  // --- Preferred-status "unknown" tracking ---------------------------------

  /**
   * Whether a preferred-status lookup could not be answered this request (Fluid
   * or Exigo errored). "Unknown" must not be read as "not preferred": the
   * rollback paths rewrite every line price, so a transient API failure would
   * otherwise cost the shopper their discount (CURRENT-3361).
   */
  get preferredLookupFailed(): boolean {
    return this.preferredLookupFailure;
  }

  private notePreferredLookupFailure(): void {
    this.preferredLookupFailure = true;
  }

  // --- The preferred-lookup cache ------------------------------------------

  /**
   * Scoped to the company, and to the IDENTITY being asked about rather than to
   * the cart, so the two carts of one shopper share the answer.
   *
   * The identifier is digested VERBATIM. Normalising it (strip/downcase) would
   * make the key stand for a different question than the one asked: the Exigo
   * query passes the raw string into `WHERE c.Email = @p`, where leading
   * whitespace is significant and the collation may be case-sensitive. A
   * normalised key would let `" a@b.com"` and `"a@b.com"` — which can genuinely
   * get different answers — share one cached result.
   *
   * `null` disables caching for this lookup rather than risking a key that
   * could collide across companies.
   */
  private preferredLookupKey(kind: string, identifier: unknown): string | null {
    const companyId = this.reportingCompanyId;
    if (isBlank(companyId) || isBlank(identifier)) return null;

    return `dynamic_pricing:preferred:${kind}:${String(companyId)}:${this.deps.cache.digest(
      String(identifier),
    )}`;
  }

  /**
   * `undefined` means "nothing cached" — a cached `false` is a real answer and
   * is returned as one. Cache trouble can never be the thing that breaks
   * pricing, so both helpers swallow and fall through to the live lookup.
   *
   * The TTL guard is on the READ as well as the write, so setting
   * PREFERRED_LOOKUP_TTL_SECONDS=0 mid-incident takes effect at once instead of
   * stopping new writes while already-written entries keep being served.
   */
  private readPreferredLookup(key: string | null): boolean | undefined {
    if (key === null || PREFERRED_LOOKUP_TTL <= 0) return undefined;
    try {
      return this.deps.cache.read(key);
    } catch (error) {
      this.deps.log.warn(
        `[DynamicPricing] preferred-lookup cache read failed: ${messageOf(error)}`,
      );
      return undefined;
    }
  }

  private writePreferredLookup(key: string | null, answer: boolean): void {
    if (key === null || PREFERRED_LOOKUP_TTL <= 0) return;
    // Never freeze the answer taken at the moment it flips. order_completion is
    // ~39% of cart_customer_attached traffic and fires while the
    // subscription-start order is being finalised, so the lookup there can
    // legitimately say "no subscriptions" about a customer who is acquiring one
    // right now. Reads still hit the cache; only the write is skipped.
    if (this.cartSettled) return;

    try {
      this.deps.cache.write(key, answer, PREFERRED_LOOKUP_TTL);
    } catch (error) {
      this.deps.log.warn(
        `[DynamicPricing] preferred-lookup cache write failed: ${messageOf(error)}`,
      );
    }
  }

  // --- Cart writes ---------------------------------------------------------

  async updateCartMetadata(metadata: Record<string, unknown>): Promise<void> {
    if (this.refuseSettledWrite("metadata")) return;

    // Transient Fluid failures intentionally propagate to the service's outer
    // rescue so the callback returns a non-success result and the failure is
    // reported; they are NOT swallowed here.
    await this.deps.fluid.appendCartMetadata(this.cartToken ?? "", metadata);
    this.deps.log.info(
      `[DynamicPricing] Stamped cart ${this.cartToken} metadata: ${JSON.stringify(metadata)}`,
    );
  }

  async updateCartItemsPrices(itemsData: PricedItem[] | null): Promise<void> {
    if (this.refuseSettledWrite("prices")) return;
    if (itemsData === null || itemsData === undefined) {
      throw new CallbackError("Items data is blank");
    }

    // Empty means every item was refused by countrySafePrice, which already
    // logged why — a deliberate no-op, not a caller error.
    if (itemsData.length === 0) {
      this.deps.log.info(
        `[DynamicPricing] No items left to reprice on cart ${this.cartToken}`,
      );
      return;
    }

    // The zero-price guard. A zero written here is an admin override that Fluid
    // then LOCKS, so the right price can never come back on its own.
    const safeItems = itemsData.filter((item) => toF(item.price) !== 0);
    if (safeItems.length < itemsData.length) {
      const dropped = itemsData.filter((item) => toF(item.price) === 0);
      this.deps.log.warn(
        `[DynamicPricing] Refusing to set zero price for cart ${this.cartToken}, ` +
          `dropped items: ${JSON.stringify(dropped.map((i) => i.id))}`,
      );
    }
    if (safeItems.length === 0) return;

    try {
      await this.deps.fluid.updateCartItemsPrices(
        this.cartToken ?? "",
        safeItems,
      );
      this.deps.log.info(
        `[DynamicPricing] Repriced ${safeItems.length} item(s) on cart ${this.cartToken}`,
      );
    } catch (error) {
      this.reportException(error, {
        message: `Failed to update cart items prices for cart ${this.cartToken}: ${messageOf(error)}`,
      });
    }
  }

  /**
   * Adjusts each item's per-unit QV/CV to reflect subscription pricing
   * (STU2-2526). No-op unless the company opted in.
   *
   * The ratio and the base CV/QV both come from the variant's variant_country —
   * the authoritative source that carries price, subscription_price, cv and qv
   * together — NOT the cart item's price fields, which can be inconsistent.
   * Items without a resolvable variant are SKIPPED rather than zeroed out, so
   * real commission values on Fluid are never wiped.
   */
  async updateCartItemsVolumes(
    items: Json[],
    mode: "subscription" | "regular",
  ): Promise<void> {
    if (!this.settings.adjustVolumesForSubscription) return;
    if (this.refuseSettledWrite("volumes")) return;

    // Constant for the whole request — resolve once, not per item.
    const source = this.settings.subscriptionVolumeSource;

    try {
      for (const item of items) {
        const itemId = field(item, "id");
        const variantId = this.itemVariantId(item);
        if (isBlank(itemId) || isBlank(variantId)) continue;

        // Caught PER ITEM, not around the loop: with a batched callback a
        // transient failure on an early item must not strand every later
        // item's volumes.
        try {
          const base = await this.variantBaseVolumes(variantId);
          if (base === null) continue;

          const volumes = cartItemVolumes(
            base,
            mode,
            field(item, "quantity"),
            source,
            this.deps.log,
            this.cartToken,
          );

          await this.deps.fluid.updateCartItemVolumes(
            this.cartToken ?? "",
            itemId,
            volumes,
          );
        } catch (error) {
          this.reportException(error, {
            message: `Failed to update volumes for item ${String(itemId)} on cart ${this.cartToken}: ${messageOf(error)}`,
          });
        }
      }
    } catch (error) {
      this.reportException(error, {
        message: `Failed to update cart item volumes for cart ${this.cartToken}: ${messageOf(error)}`,
      });
    }
  }

  // --- Price resolution ----------------------------------------------------

  /**
   * The payload's own subscription price for one item.
   *
   * Zero-aware: a bundle's `"0.0"` is a truthy String in Ruby, so a plain `||`
   * on the raw field would stop there and write zero. The single home for this
   * fallback chain — the validation in `updateItemToSubscriptionPrice` and the
   * PATCH builder must never disagree about it.
   */
  subscriptionPayloadPrice(item: Json): unknown {
    return (
      nonzeroPrice(field(item, "subscription_price")) ??
      bundleGroupBasePrice(item) ??
      field(item, "price")
    );
  }

  /**
   * `{ id, price }` per cart item at its subscription price, resolved from the
   * cart's country. Items `countrySafePrice` refuses are dropped.
   */
  async cartItemsWithSubscriptionPrice(
    items: Json[] = this.cartItems,
  ): Promise<PricedItem[]> {
    const out: PricedItem[] = [];
    for (const item of items) {
      const price = await this.countrySafePrice(
        item,
        this.subscriptionPayloadPrice(item),
        "subscription",
      );
      if (price === null) continue;
      out.push({ id: field(item, "id"), price });
    }
    return out;
  }

  /** As above, at the non-subscription price. */
  async cartItemsWithRegularPrice(
    items: Json[] = this.cartItems,
  ): Promise<PricedItem[]> {
    const out: PricedItem[] = [];
    for (const item of items) {
      const payloadPrice =
        nonzeroPrice(field(field<Json>(item, "product"), "price")) ??
        bundleGroupBasePrice(item) ??
        field(item, "price");
      const price = await this.countrySafePrice(item, payloadPrice, "regular");
      if (price === null) continue;
      out.push({ id: field(item, "id"), price });
    }
    return out;
  }

  /**
   * Lines this droplet wrote: Fluid stamps `price_locked` on every price we set
   * and then skips them when it reprices, so these are the only ones a country
   * change can strand.
   */
  get lockedCartItems(): Json[] {
    return this.cartItems.filter(
      (item) => field(field<Json>(item, "metadata"), "price_locked") === true,
    );
  }

  /**
   * The price to write for `item` (STU2-3108). Echoing the payload let a price
   * Fluid had resolved against ANOTHER country be written as an admin override
   * and locked, so the right price could never come back — a PH cart was
   * charged the CAD figure, 113.85 instead of 2,499.
   *
   * The payload still wins by default. Fluid resolves a price through more than
   * the variant_country columns — a percentage subscription plan computes off
   * the retail price, a wholesale rep reads the wholesale columns — so
   * replacing its figure outright would trade this bug for a wider one. The row
   * is used only once the payload is SHOWN to belong to a country the cart is
   * not in.
   *
   * Returns a number, or null to skip the item entirely.
   */
  async countrySafePrice(
    item: Json,
    payloadPrice: unknown,
    kind: "subscription" | "regular",
  ): Promise<number | null> {
    const variantId = this.itemVariantId(item);
    if (isBlank(variantId)) return toF(payloadPrice);

    // A bundle's price never comes from variant_country. Its master variant may
    // well carry priced rows while its lines price at 0.0, so reading the row
    // would overwrite Fluid's bundle total and lock it.
    if (bundlePriced(item)) return toF(payloadPrice);

    // Log-only for now: refusing is the safer end state, but it would also stop
    // repricing a guest cart with no address yet.
    if (isBlank(this.cartPricingCountry)) {
      this.deps.log.warn(
        `[DynamicPricing] Cannot resolve the pricing country for item ${String(field(item, "id"))} ` +
          `on cart ${this.cartToken} (variant ${String(variantId)}); forwarding the payload price ` +
          `${JSON.stringify(payloadPrice)} unchecked`,
      );
      return toF(payloadPrice);
    }

    // Lookup failed — fall through rather than block the reprice on a blip.
    const rows = await this.variantCountryRows(variantId);
    if (rows === null || rows.length === 0) return toF(payloadPrice);

    const foreign = this.foreignPricedRow(rows, payloadPrice);
    if (foreign === null) return toF(payloadPrice);

    const priceField =
      kind === "subscription" ? "subscription_price" : "price";
    const ownRow = await this.variantCountryRow(variantId);
    const authoritative = toF(field(ownRow ?? undefined, priceField));
    if (authoritative > 0) return authoritative;

    // The payload is another country's and the cart's own row has nothing to
    // put in its place — fee and adjustment SKUs sit at 0.0 everywhere.
    return this.refuseCrossCountryPrice(
      item,
      variantId,
      payloadPrice,
      foreign,
      priceField,
      ownRow,
    );
  }

  /**
   * A row for a country OTHER than the cart's matching `value` — and only when
   * the cart's own row cannot explain it. If the number is in your own
   * country's row it did not come from elsewhere, whatever the other rows hold.
   * Without that half, a US cart handed its own `wholesale` was called foreign
   * because AU shared the figure (Oliabo cart 757644), dropping a correct
   * write.
   *
   * Still a heuristic — two countries may share a price — and it fails toward a
   * skipped reprice and an alert, never a wrong charge.
   */
  private foreignPricedRow(rows: Json[], value: unknown): Json | null {
    const amount = toF(value);
    if (!(amount > 0)) return null;

    const own = rows.filter(
      (row) => field(row, "country_code") === this.cartPricingCountry,
    );
    const foreign = rows.filter(
      (row) => field(row, "country_code") !== this.cartPricingCountry,
    );

    if (own.some((row) => rowPrices(row).some((p) => sameMoney(p, amount)))) {
      return null;
    }

    return (
      foreign.find((row) =>
        rowPrices(row).some((p) => sameMoney(p, amount)),
      ) ?? null
    );
  }

  /**
   * Drops the write either way; ALERTS only when the cart's country has an
   * ACTIVE row.
   *
   * Fluid creates a row per company country, so one the variant is not sold in
   * still exists — inactive, at 0.00 — and `variantCountryRow` skips it, as
   * Fluid does. With no active row Fluid prices nothing and blocks the line at
   * checkout: expected, and nothing to action. An active row at 0.00 still
   * alerts, since the variant IS sold there and its price is missing.
   */
  private refuseCrossCountryPrice(
    item: Json,
    variantId: unknown,
    payloadPrice: unknown,
    foreign: Json,
    priceField: string,
    ownRow: Json | null,
  ): null {
    const foreignCountry = field(foreign, "country_code");
    const expected = field(ownRow ?? undefined, priceField);
    const message =
      `[DynamicPricing] Refusing cross-country price for item ${String(field(item, "id"))} ` +
      `(variant ${String(variantId)}) on cart ${this.cartToken}: payload price ${toF(payloadPrice)} ` +
      `belongs to ${String(foreignCountry)} (${String(field(foreign, "currency_code"))}), but the ` +
      `cart's country is ${String(this.cartPricingCountry)} whose ${priceField} is ${JSON.stringify(expected)}`;

    if (ownRow === null) {
      this.deps.log.info(
        `${message} — not sold in ${String(this.cartPricingCountry)}, so the line is unbuyable there ` +
          "and Fluid blocks it at checkout. Expected, not reported.",
      );
      return null;
    }

    this.deps.log.warn(message);
    this.reportException(new CrossCountryPriceError(message), {
      item_id: field(item, "id"),
      variant_id: variantId,
      cart_country: this.cartPricingCountry,
      payload_price: payloadPrice,
      expected_price: expected,
      foreign_country: foreignCountry,
    });
    return null;
  }

  // --- Variant / country resolution ----------------------------------------

  itemVariantId(item: Json): unknown {
    return (
      field(item, "variant_id") ?? field(field<Json>(item, "variant"), "id")
    );
  }

  /**
   * The cart's OWN country, where its currency comes from — the only country a
   * price may be resolved against. Narrower than `cartCountry` on purpose:
   * taking a price from ship_to while the currency comes from the cart IS the
   * STU2-3108 bug.
   */
  get cartPricingCountry(): unknown {
    const own = field(this.cart, "country_code");
    if (isPresent(own)) return own;

    const country = field(this.cart, "country");
    if (typeof country === "string") return country;
    if (isObject(country)) return field(country, "iso");
    return undefined;
  }

  /** Volume resolution ONLY — anything deciding a PRICE uses `cartPricingCountry`. */
  get cartCountry(): unknown {
    return (
      this.cartPricingCountry ??
      field(field<Json>(this.cart, "ship_to"), "country_code") ??
      field(field<Json>(this.cart, "shipping_address"), "country_code")
    );
  }

  /**
   * The variant's ACTIVE row for the cart's own country, mirroring
   * `CartItem#variant_country_for_country_id`: inactive means the company does
   * not sell it there, so there is no price to use. An ABSENT flag counts as
   * active — the live endpoint always sends it, and reading a missing key as
   * "not sold" would stop pricing everything at once.
   */
  async variantCountryRow(variantId: unknown): Promise<Json | null> {
    if (isBlank(this.cartPricingCountry)) return null;

    const rows = await this.variantCountryRows(variantId);
    if (rows === null || rows.length === 0) return null;

    return (
      rows.find((row) => {
        if (field(row, "country_code") !== this.cartPricingCountry) return false;
        const active = field(row, "active");
        return active === undefined || active === null || Boolean(active);
      }) ?? null
    );
  }

  /**
   * Memoized per request (null included) since items share variants and both
   * the volume and price paths need them. null when the variant cannot be
   * fetched.
   */
  async variantCountryRows(variantId: unknown): Promise<Json[] | null> {
    const key = String(variantId);
    if (this.variantCountryRowsCache.has(key)) {
      return this.variantCountryRowsCache.get(key) ?? null;
    }

    try {
      const response = await this.deps.fluid.getVariant(key);
      const variant = field<Json>(response, "variant");
      const rows = field(variant, "variant_countries");
      const value = Array.isArray(rows) ? (rows.filter(isObject) as Json[]) : [];
      this.variantCountryRowsCache.set(key, value);
      return value;
    } catch (error) {
      this.deps.log.error(
        `Failed to fetch variant ${key} country rows: ${messageOf(error)}`,
      );
      this.variantCountryRowsCache.set(key, null);
      return null;
    }
  }

  /**
   * The variant's per-unit base CV/QV plus prices, falling back to the FIRST
   * country entry. Resolves its own row rather than reusing
   * `variantCountryRow`: volumes are STU2-2526's and stay exactly as that
   * ticket left them.
   */
  private async variantBaseVolumes(
    variantId: unknown,
  ): Promise<VariantBaseVolumes | null> {
    const rows = await this.variantCountryRows(variantId);
    if (rows === null || rows.length === 0) return null;

    const match =
      rows.find((row) => field(row, "country_code") === this.cartCountry) ??
      rows[0];
    if (!match) return null;

    return {
      cv: toF(field(match, "cv")),
      qv: toF(field(match, "qv")),
      pcCv: field(match, "pc_cv"),
      pcQv: field(match, "pc_qv"),
      price: field(match, "price"),
      subscriptionPrice: field(match, "subscription_price"),
    };
  }

  // --- Preferred-customer questions ----------------------------------------

  async getCustomerIdByEmail(email: string | undefined): Promise<unknown> {
    if (isBlank(email)) return null;

    try {
      const response = await this.deps.fluid.listCustomers({ email: email! });
      const customers = response.customers ?? [];
      return customers.length > 0 ? field(customers[0], "id") : null;
    } catch (error) {
      this.deps.log.error(
        `Failed to get customer ID by email ${email}: ${messageOf(error)}`,
      );
      return null;
    }
  }

  /**
   * Memoized per request (null included): the login path reads this twice for
   * the same customer.
   *
   * Only an ANSWER is memoized. A failed read has to stay retryable: memoizing
   * its null would hand `syncPccMetafield` a "not preferred" it never verified,
   * and it would then spend ensureDefinition + PATCH (+ POST) correcting a
   * value it cannot actually see — 2-3 Fluid calls on the most
   * budget-constrained path.
   */
  async getCustomerTypeFromMetafields(customerId: unknown): Promise<unknown> {
    const key = String(customerId);
    if (this.customerTypeMetafieldCache.has(key)) {
      return this.customerTypeMetafieldCache.get(key);
    }

    let failed = false;
    let value: unknown;
    try {
      value = await this.readCustomerTypeMetafield(customerId);
    } catch {
      // A customer with no customer_type metafield returns null WITHOUT
      // raising, so reaching here means the lookup itself failed, not that the
      // answer is "retail".
      failed = true;
      this.notePreferredLookupFailure();
      value = undefined;
    }

    if (!failed) this.customerTypeMetafieldCache.set(key, value);
    return value;
  }

  private async readCustomerTypeMetafield(
    customerId: unknown,
  ): Promise<unknown> {
    const metafield = await this.deps.fluid.getMetafieldByKey({
      resource_type: "customer",
      resource_id: String(customerId),
      key: "customer_type",
    });
    return field(field<Json>(metafield ?? undefined, "value"), "customer_type");
  }

  get hasAnotherSubscriptionInCart(): boolean {
    return this.cartItems.some((item) => field(item, "subscription") === true);
  }

  /**
   * True when the cart should get preferred/subscription pricing even though it
   * is not stamped. The stamp lives in Fluid's cart metadata and can be missing
   * on a given callback (e.g. the cart was emptied after the attach/login that
   * stamped it), so item_added / item_updated cannot rely on the flag alone.
   *
   * ORDER MATTERS FOR COST: the in-cart check is free; the subscription lookups
   * hit external APIs and only run when the cart carries no subscription line.
   */
  async cartQualifiesForPreferredPricing(): Promise<boolean> {
    if (this.hasAnotherSubscriptionInCart) return true;
    return this.customerHasActiveSubscription();
  }

  /**
   * A live Fluid subscription, or an active Exigo autoship when the company
   * runs Exigo. The Fluid lookup needs a customer_id so it is gated behind a
   * logged-in customer; the Exigo lookup is by email and works on guest carts
   * too.
   */
  private async customerHasActiveSubscription(): Promise<boolean> {
    if (
      this.customerLoggedIn &&
      (await this.hasActiveSubscriptions(this.cartCustomerId))
    ) {
      return true;
    }
    return this.exigoPreferredByEmail(this.customerEmail);
  }

  async hasActiveSubscriptions(customerId: unknown): Promise<boolean> {
    const key = this.preferredLookupKey("fluid_subscriptions", customerId);
    const cached = this.readPreferredLookup(key);
    if (cached !== undefined) return cached;

    try {
      const response = await this.deps.fluid.listSubscriptionsByCustomer(
        String(customerId),
        { status: "active" },
      );
      const subscriptions = field(response, "subscriptions");
      const answer = Array.isArray(subscriptions) && subscriptions.length > 0;

      // A 200 is NOT the same as an answer. An empty body, a `{}`, an error
      // object served 200, or a change in response shape all collapse to
      // `false` — and `false` is the value that unlocks the strip branch in
      // customerLoggedIn, which rewrites every line to retail. Caching that
      // would spread one degenerate response across every cart of this customer
      // for the whole window, so it is returned but never written.
      if (response && typeof response === "object" && "subscriptions" in response) {
        this.writePreferredLookup(key, answer);
      } else {
        this.deps.log.warn(
          `[DynamicPricing] subscriptions lookup for ${String(customerId)} answered without a ` +
            `subscriptions key; not caching ${answer}`,
        );
      }

      return answer;
    } catch (error) {
      this.deps.log.error(
        `Error checking active subscriptions for customer ${String(customerId)}: ${messageOf(error)}`,
      );
      this.notePreferredLookupFailure();
      return false;
    }
  }

  /**
   * Which Exigo question is asked is per installation — an active autoship (the
   * default, and today's behaviour everywhere) or the customer's CustomerTypeID.
   *
   * Keyed by SIGNAL, not by a shared `exigo_autoship`: the two answer different
   * questions, so a company that flips the setting must not read back the other
   * signal's cached answer.
   */
  async exigoPreferredByEmail(email: string | undefined): Promise<boolean> {
    if (!this.settings.exigoEnabled) return false;
    if (isBlank(email)) return false;

    const byCustomerType = this.settings.exigoPreferredByCustomerType;
    const key = this.preferredLookupKey(
      byCustomerType ? "exigo_customer_type" : "exigo_autoship",
      email,
    );
    const cached = this.readPreferredLookup(key);
    if (cached !== undefined) return cached;

    try {
      const exigo = this.deps.exigo;
      if (exigo === null) {
        throw new CallbackError("Exigo integration not enabled");
      }

      const answer = byCustomerType
        ? await this.exigoCustomerTypeMatches(exigo, email!)
        : await exigo.customerHasActiveAutoshipByEmail(email!);

      // Both Exigo reads return a strict boolean, so unlike the Fluid lookup
      // above there is no "200 with no answer" shape to guard against.
      this.writePreferredLookup(key, answer);
      return answer;
    } catch (error) {
      this.deps.log.error(
        `Error checking Exigo preferred status for email ${email}: ${messageOf(error)}`,
      );
      this.notePreferredLookupFailure();
      return false;
    }
  }

  /**
   * `String()` on BOTH sides: Exigo hands back CustomerTypeID as an Integer,
   * while `preferredCustomerTypeId` is a String everywhere it comes from (the
   * JSONB default is "2", and the admin form writes a text field). Comparing
   * them raw is `2 === "2"` — false for every customer.
   */
  private async exigoCustomerTypeMatches(
    exigo: NonNullable<PricingDeps["exigo"]>,
    email: string,
  ): Promise<boolean> {
    const customerType = await exigo.customerTypeByEmail(email);
    if (customerType === null || customerType === undefined) return false;
    return String(customerType) === String(this.settings.preferredCustomerTypeId);
  }

  async isPreferredCustomer(email: string | undefined): Promise<boolean> {
    if (isBlank(email)) return false;

    const customerId =
      this.cartCustomerId ?? (await this.getCustomerIdByEmail(email));

    // The active-subscription override below is kept on BOTH sources on
    // purpose. It exists so the two callback paths cannot disagree and
    // oscillate the cart price (STU2-2531), and on the member-type path it is
    // not redundant with the member type: it is a BEHAVIOURAL signal rather
    // than an assigned one, so it catches a connector that has not caught up
    // with a new autoship yet.
    if (this.settings.preferredFromFluidMemberType) {
      if (await this.fluidMemberPreferred(customerId, email)) return true;
      if (isPresent(customerId) && (await this.hasActiveSubscriptions(customerId))) {
        return true;
      }
      // No Exigo fallback: the whole point of this source is that the
      // installation does not read Exigo.
      return false;
    }

    if (isPresent(customerId)) {
      const customerType = await this.getCustomerTypeFromMetafields(customerId);
      if (customerType === PREFERRED_CUSTOMER_TYPE) return true;
      if (await this.hasActiveSubscriptions(customerId)) return true;
    }

    return this.exigoPreferredByEmail(email);
  }

  /**
   * Resolves the Fluid member behind this cart and answers whether Fluid itself
   * calls them preferred. The customer id is `members.legacy_customer_id`,
   * which `find` matches on directly, so there is no mapping to keep; the email
   * is the fallback for a cart with no customer attached yet.
   *
   * Memoizes an answer but NEVER a failure, for the same reason
   * `getCustomerTypeFromMetafields` does not.
   */
  private async fluidMemberPreferred(
    customerId: unknown,
    email: string | undefined,
  ): Promise<boolean> {
    const identifier: Record<string, string | number> = isPresent(customerId)
      ? { legacy_customer_id: String(customerId) }
      : { email: String(email ?? "") };
    const identity = Object.values(identifier)[0];
    if (isBlank(identity)) return false;

    const key = JSON.stringify(identifier);
    if (this.memberPreferredCache.has(key)) {
      return this.memberPreferredCache.get(key) ?? false;
    }

    try {
      const answer =
        (await this.deps.fluid.readMemberTypeSlug(identifier)) ===
        this.deps.preferredMemberSlug;
      this.memberPreferredCache.set(key, answer);
      return answer;
    } catch (error) {
      // No member matched. That is a real NEGATIVE, the same way a customer
      // with no customer_type metafield is — not a lookup that failed.
      if (this.deps.fluid.isNotFound(error)) {
        this.memberPreferredCache.set(key, false);
        return false;
      }
      this.deps.log.error(
        `Failed to read Fluid member type for ${key}: ${messageOf(error)}`,
      );
      this.notePreferredLookupFailure();
      return false;
    }
  }

  // --- Metafield writes ----------------------------------------------------

  async updatePccMetafield(
    fluidCustomerId: unknown,
    customerType: string,
  ): Promise<void> {
    if (isBlank(fluidCustomerId) || isBlank(customerType)) return;

    // Built BEFORE the first call, not between the two: ensureDefinition can
    // itself raise not-found, and the fallback below then reached `create` with
    // the value still unset — where "value cannot be blank" made the fallback
    // impossible and blamed the wrong thing in the log.
    const jsonValue = { customer_type: String(customerType) };
    const description =
      "Customer type for pricing (preferred_customer, retail, null)";

    try {
      await this.deps.fluid.ensureMetafieldDefinition({
        namespace: "custom",
        key: "customer_type",
        value_type: "json",
        description,
        owner_resource: "Customer",
      });

      await this.deps.fluid.updateMetafield({
        resource_type: "customer",
        resource_id: toI(fluidCustomerId),
        namespace: "custom",
        key: "customer_type",
        value: jsonValue,
        value_type: "json",
        description,
      });
    } catch (error) {
      if (this.deps.fluid.isNotFound(error)) {
        try {
          await this.deps.fluid.createMetafield({
            resource_type: "customer",
            resource_id: toI(fluidCustomerId),
            namespace: "custom",
            key: "customer_type",
            value: jsonValue,
            value_type: "json",
            description,
          });
          return;
        } catch (createError) {
          this.deps.log.error(
            `Failed to update PCC metafield for customer ${String(fluidCustomerId)}: ${messageOf(createError)}`,
          );
          return;
        }
      }
      this.deps.log.error(
        `Failed to update PCC metafield for customer ${String(fluidCustomerId)}: ${messageOf(error)}`,
      );
    }
  }

  // --- Shared service behaviour --------------------------------------------

  /**
   * Reprices the callback's cart item to its subscription price (falling back
   * to the regular price) and adjusts its volumes. Shared by cartItemAdded and
   * cartItemUpdated so the two pricing paths cannot silently diverge.
   */
  async updateItemToSubscriptionPrice(): Promise<void> {
    const items = this.callbackCartItems;
    if (items.some((item) => isBlank(field(item, "id")))) {
      throw new CallbackError("Item ID is required");
    }
    if (items.some((item) => isBlank(this.subscriptionPayloadPrice(item)))) {
      throw new CallbackError("Item price is not present in cart item");
    }

    // Items countrySafePrice refuses are dropped, and already logged. Volumes
    // still go for every item: they come from the country-matched row and
    // self-skip without one.
    const pricedItems = await this.cartItemsWithSubscriptionPrice(items);

    // Only the items the callback names — one PATCH for the whole batch. Lines
    // left behind in a previous country are cartCountryChanged's, which
    // corrects the whole cart at once.
    if (pricedItems.length > 0) await this.updateCartItemsPrices(pricedItems);
    await this.updateCartItemsVolumes(items, "subscription");
  }

  // --- Bookkeeping ---------------------------------------------------------

  async logCartPricingEvent(params: {
    eventType: string;
    preferredApplied: boolean;
    additionalData?: Record<string, unknown>;
  }): Promise<void> {
    try {
      await this.deps.recordCartPricingEvent({
        companyId: this.deps.company.id,
        cartId: field(this.cart, "id"),
        email: field(this.cart, "email"),
        eventType: params.eventType,
        preferredPricingApplied: params.preferredApplied,
        itemsCount: this.cartItems.length,
        cartTotal: this.calculateCartTotal(),
        metadata: params.additionalData ?? {},
      });
    } catch (error) {
      this.reportException(error, {
        message: `[CartPricingEvent] Failed to log event: ${messageOf(error)}`,
      });
    }
  }

  calculateCartTotal(): number {
    try {
      return this.cartItems.reduce(
        (total, item) =>
          total + toF(field(item, "price")) * Math.max(toI(field(item, "quantity")), 1),
        0,
      );
    } catch {
      return 0;
    }
  }

  /**
   * Logs an exception and reports it with cart/customer context.
   *
   * The callback services deliberately swallow most write failures so a single
   * Fluid hiccup never fails the whole callback; that silence is why bugs here
   * went unnoticed. This surfaces the swallowed failures instead. Best-effort:
   * it never raises itself.
   */
  reportException(
    error: unknown,
    context: Record<string, unknown> = {},
  ): void {
    const { message, ...extra } = context as { message?: string } & Record<
      string,
      unknown
    >;
    try {
      if (message) this.deps.log.error(message);
      this.deps.reportException(error, {
        // The droplet is shared and cart_token is scrubbed as PII, so without
        // this an alert says nothing about which tenant raised it.
        company_id: this.reportingCompanyId,
        cart_token: this.cartToken,
        cart_id: field(this.cart, "id"),
        customer_id: this.cartCustomerId,
        ...extra,
      });
    } catch (reportingError) {
      this.deps.log.error(
        `[Sentry] Failed to report exception: ${messageOf(reportingError)}`,
      );
    }
  }

  /**
   * From the PAYLOAD, not the resolved company: reporting must never be the
   * thing that raises, and an unresolvable company is what a report may well be
   * describing.
   */
  get reportingCompanyId(): unknown {
    return field(field<Json>(this.cart, "company"), "id");
  }

  // --- Result builders -----------------------------------------------------

  resultSuccess(): CallbackResult {
    return { success: true };
  }

  successWithMessage(message: string): CallbackResult {
    return { success: true, message };
  }

  /**
   * A response that affirms the preferred_customer price_type on the response
   * channel Fluid applies back to the cart. Pair with `updateCartMetadata` to
   * also persist the slug for the next cart event — the price goes to the cart
   * items while the slug lives in cart metadata AND the callback response, and
   * the two are not atomic.
   */
  preferredPricingResponse(message?: string): CallbackResult {
    const response: CallbackResult = {
      success: true,
      metadata: { price_type: PREFERRED_CUSTOMER_TYPE },
    };
    if (message) response.message = message;
    return response;
  }

  handleCallbackError(error: CallbackError, serviceName: string): CallbackResult {
    this.deps.log.error(`[${serviceName}] ${error.message}`);
    return { success: false, message: error.message };
  }
}

// --- Free functions the context and its tests both use ---------------------

export function isObject(value: unknown): value is Json {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** `value` unless blank or numerically zero, so a `||` chain keeps walking. */
export function nonzeroPrice(value: unknown): unknown {
  if (isBlank(value)) return undefined;
  return toF(value) === 0 ? undefined : value;
}

/**
 * Fluid's own bundle figure, already in the cart's currency.
 *
 * DELIBERATELY not zero-aware: `"0.0"` means the bundle really prices at zero,
 * and the zero-price guard then drops the write and leaves the line as Fluid
 * left it.
 */
export function bundleGroupBasePrice(item: Json): unknown {
  const value = field(field<Json>(item, "metadata"), "bundle_group_base_price");
  return isBlank(value) ? undefined : value;
}

/**
 * A bundle's price never comes from variant_country.
 *
 * Broader than Fluid's `ItemPricing#use_bundle_group_pricing?`, which also asks
 * whether the product has bundle groups — the droplet cannot see that, and
 * guessing fails in the dangerous direction.
 */
export function bundlePriced(item: Json): boolean {
  return field(field<Json>(item, "metadata"), "is_bundle") === true;
}

function rowPrices(row: Json): unknown[] {
  return PRICE_COLUMNS.map((column) => field(row, column));
}

function sameMoney(one: unknown, two: unknown): boolean {
  if (one === null || one === undefined) return false;
  if (two === null || two === undefined) return false;
  return round2(toF(one)) === round2(toF(two));
}

function round2(value: number): number {
  return Math.round(value * 100) / 100;
}

/**
 * Per-unit CV/QV to write for a cart item, honouring the company's
 * `subscription_volume_source`.
 *
 * When the catalog is missing pc_cv/pc_qv it writes the variant's RETAIL
 * volumes as-is (and logs) rather than the price_ratio result, so a catalog
 * misconfig surfaces as plainly unadjusted volumes instead of silently
 * masquerading as a valid ratio calc.
 */
export function cartItemVolumes(
  base: VariantBaseVolumes,
  mode: "subscription" | "regular",
  quantity: unknown,
  source: string,
  log: PricingDeps["log"],
  cartToken: string | undefined,
): Volumes {
  if (mode === "subscription" && source === PREFERRED_CUSTOMER_VOLUME_SOURCE) {
    let cv: unknown;
    let qv: unknown;
    if (isPresent(base.pcCv) && isPresent(base.pcQv)) {
      cv = base.pcCv;
      qv = base.pcQv;
    } else {
      log.warn(
        "[DynamicPricing] subscription_volume_source=preferred_customer but variant " +
          `is missing pc_cv/pc_qv; writing retail volumes for cart ${cartToken}`,
      );
      cv = base.cv;
      qv = base.qv;
    }

    return {
      cv: scaledUnitVolume(cv, 1.0, quantity),
      qv: scaledUnitVolume(qv, 1.0, quantity),
    };
  }

  const ratio = mode === "subscription" ? subscriptionValueRatio(base) : 1.0;
  return {
    cv: scaledUnitVolume(base.cv, ratio, quantity),
    qv: scaledUnitVolume(base.qv, ratio, quantity),
  };
}

/**
 * Fraction of base volume to keep under subscription pricing =
 * subscription_price / retail price, clamped to [0, 1]. Falls back to 1.0 (no
 * reduction) when the variant's prices are missing or non-positive.
 */
export function subscriptionValueRatio(base: VariantBaseVolumes): number {
  const retail = toF(base.price);
  const subscription = toF(base.subscriptionPrice);
  if (retail <= 0 || subscription <= 0) return 1.0;
  return Math.min(Math.max(subscription / retail, 0), 1);
}

/**
 * Per-unit volume scaled by `ratio`. Rounded on the LINE TOTAL (base * qty)
 * then divided back per unit, matching Fluid core's rounding.
 *
 * Ruby's `Float#round` is half-to-even only for `.5` at the midpoint of an
 * exactly-representable value; in practice both engines round half away from
 * zero here, and these are non-negative, so `Math.round` agrees.
 */
export function scaledUnitVolume(
  baseUnit: unknown,
  ratio: number,
  quantity: unknown,
): number {
  const unit = toF(baseUnit);
  const qty = Math.max(toI(quantity), 1);
  const total = Math.round(unit * qty * ratio);
  return Math.max(Math.round(total / qty), 0);
}

export function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
