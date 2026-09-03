/**
 * The payload requirements the Rails controllers enforced.
 *
 * `Callbacks::BaseController`'s subclasses permitted `cart: {}` — Rails' "any
 * hash" filter, which validates nothing — and then called `require` on a small
 * set of keys. Those `require`s were hard failures (400), so they are the only
 * part of the shape that is checked here. Everything else stays loose: Fluid
 * adds fields to these payloads over time and a new one must never turn a
 * repricing callback into a rejection.
 *
 * `MissingParameterError` is `ActionController::ParameterMissing`. Each route
 * decides what to answer with — the eight fail-closed routes return 400 and the
 * one fail-open route returns its neutral 200.
 */

import { isObject } from "./context";
import type { CallbackParams, Json } from "./types";

export class MissingParameterError extends Error {
  constructor(readonly parameter: string) {
    super(`param is missing or the value is empty: ${parameter}`);
    this.name = "MissingParameterError";
  }
}

/**
 * Ruby's `require`: present, and not `nil`, `false`, `""`, `[]` or `{}`.
 *
 * Note this is `blank?`, not "key exists" — `cart.require(:email)` on a cart
 * whose email is `""` raised in Rails, and the route answered 400.
 */
function requireValue(record: Json | undefined, key: string, path: string): unknown {
  const value = record?.[key];
  const blank =
    value === null ||
    value === undefined ||
    value === false ||
    (typeof value === "string" && value.trim().length === 0) ||
    (Array.isArray(value) && value.length === 0) ||
    (isObject(value) && Object.keys(value).length === 0);
  if (blank) throw new MissingParameterError(path);
  return value;
}

export type CallbackShape =
  | "cart_and_item"
  | "cart_only"
  | "cart_with_email"
  | "cart_with_customer";

/**
 * Validates a parsed callback body and narrows it to `CallbackParams`.
 *
 * The four shapes map onto the nine Rails controllers:
 *
 *  - `cart_and_item`     — cart_item_added, cart_item_updated
 *  - `cart_only`         — cart_subscription_added, cart_subscription_removed,
 *                          cart_customer_detached, cart_country_changed
 *  - `cart_with_email`   — cart_customer_logged_in (and, separately,
 *                          cart_email_on_create, which requires no cart_token)
 *  - `cart_with_customer`— cart_customer_attached
 */
export function requireCallbackShape(
  payload: unknown,
  shape: CallbackShape,
): CallbackParams {
  if (!isObject(payload)) throw new MissingParameterError("cart");

  const params = payload as CallbackParams;
  const cart = requireValue(params, "cart", "cart") as Json;

  // Every controller reaching here required cart_token. `cart_email_on_create`
  // is the one that did not, and it has its own function below.
  requireValue(cart, "cart_token", "cart_token");
  requireValue(requireValue(cart, "company", "company") as Json, "id", "id");

  if (shape === "cart_and_item") requireValue(params, "cart_item", "cart_item");
  if (shape === "cart_with_email") requireValue(cart, "email", "email");

  return params;
}

/**
 * `cart_email_on_create` alone.
 *
 * Its controller required `cart`, `cart.email` and `cart.company.id` — and NOT
 * `cart.cart_token`, because a cart being created may not have one yet. Kept
 * separate rather than folded into a flag so the difference is visible.
 */
export function requireEmailOnCreateShape(payload: unknown): CallbackParams {
  if (!isObject(payload)) throw new MissingParameterError("cart");

  const params = payload as CallbackParams;
  const cart = requireValue(params, "cart", "cart") as Json;
  requireValue(cart, "email", "email");
  requireValue(requireValue(cart, "company", "company") as Json, "id", "id");

  return params;
}
