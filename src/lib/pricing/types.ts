/**
 * Shapes at the pricing engine's edge.
 *
 * These are DELIBERATELY loose. `Callbacks::BaseController` permitted
 * `cart: {}`, `cart_item: {}` and `context: {}` — Rails' "accept any hash"
 * filter — and the services then read whatever keys happened to be there. A
 * strict schema here would be a behaviour change: Fluid adds fields to these
 * payloads over time, and a new field must never turn a repricing callback into
 * a 400.
 *
 * What IS validated is the small set of keys the Rails controllers required
 * with `require`, since those were already hard failures. See
 * `requireCallbackShape`.
 */

export type Json = Record<string, unknown>;

/** The whole callback body, after the SDK has verified and parsed it. */
export interface CallbackParams {
  cart?: Json;
  cart_item?: Json;
  /**
   * Present only for companies on Fluid's BATCH_CART_ITEM_CALLBACKS flag, which
   * send one `cart_item_added` per add operation with every added item here
   * (the first element identical to `cart_item`).
   */
  cart_items?: unknown;
  /** A top-level SIBLING of `cart`, not a cart field. */
  context?: Json;
  customer?: Json;
  callback_name?: string;
  [key: string]: unknown;
}

/**
 * What a callback answers with.
 *
 * `success` is required: Fluid's `classify_response` marks a 200 whose body
 * fails the definition's response schema as `:schema_invalid`, which alerts.
 *
 * Keys are restricted to `success` / `message` / `metadata` / `error` because
 * Fluid's `build_response_data` does `Data.define(*payload.keys)` — a key that
 * is not a valid Ruby identifier (say `"error-code"`) raises `NameError` inside
 * `request.on_complete`, which escapes `hydra.run` and is NOT caught by the
 * subscribers' `rescue ::Callback::Client::Error`.
 */
export interface CallbackResult {
  success: boolean;
  message?: string;
  metadata?: Record<string, string>;
  error?: string;
}

export const PREFERRED_CUSTOMER_TYPE = "preferred_customer";

/**
 * Cart states in which Fluid has already taken the shopper's money. The cart is
 * closed to modification, so a price write either bounces with 410 or lands on
 * an order that has already been charged, leaving the captured amount and the
 * order total disagreeing (CURRENT-3361).
 *
 * Deliberately a DENYLIST of settled states rather than an allowlist of mutable
 * ones: a state we have not seen must fall through to "reprice" (Fluid's own
 * 410 is the backstop) instead of silently switching pricing off on a live
 * cart.
 */
export const SETTLED_CART_STATES = ["payment_authorized", "payment_captured"];

/**
 * Callback triggers that only fire once the order exists. There is no cart left
 * to price at that point, whatever state the payload reports.
 */
export const POST_ORDER_TRIGGERS = ["order_completion"];

/** Raised for the conditions Rails raised `CallbackError` for. */
export class CallbackError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "CallbackError";
  }
}

/** Raised — and reported to Sentry — by the STU2-3108 cross-country guard. */
export class CrossCountryPriceError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "CrossCountryPriceError";
  }
}

/** One `{ id, price }` entry of an `update_cart_items_prices` PATCH. */
export interface PricedItem {
  id: unknown;
  price: number;
}

/** The per-unit CV/QV written by `update_volumes`. */
export interface Volumes {
  cv: number;
  qv: number;
}

/** A variant_country row, reduced to the fields the volume path reads. */
export interface VariantBaseVolumes {
  cv: number;
  qv: number;
  pcCv: unknown;
  pcQv: unknown;
  price: unknown;
  subscriptionPrice: unknown;
}
