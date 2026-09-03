/**
 * `cart_email_on_create` — the ONE route of the nine whose response Fluid
 * applies back to the cart, and therefore the only one that fails OPEN.
 *
 * Rails route: `POST /callbacks/cart_email_on_create`
 * (`Callbacks::CartEmailOnCreateController`).
 *
 * ## Why this one is different
 *
 * `Commerce::Api::Carts::CreateAction#enrich_cart_metadata` merges
 * `response.metadata` into `cart.metadata` with `update_column`, and skips the
 * response entirely unless `response.success?` — which is
 * `Typhoeus::Response#success?`, i.e. the HTTP STATUS, not the body's `success`
 * field. So a non-2xx here silently drops the cart's `price_type` stamp, and
 * the shopper is charged retail with no error anywhere.
 *
 * The other eight routes fail closed precisely because their responses are
 * discarded. This one is the exception, and the exception is narrow.
 *
 * ## The neutral body, and its two constraints
 *
 * `{ "success": true }` — used byte-identically for auth failures, invalid
 * bodies, handler errors and the legitimate "regular customer" path.
 *
 *  1. **It must NOT contain `metadata`.** Returning
 *     `{success: true, metadata: {price_type: "preferred_customer"}}` on an
 *     auth failure would stamp preferred pricing onto a cart that has not
 *     earned it. `enrich_cart_metadata` also requires `metadata.present?`, so a
 *     body without it is a no-op on the cart — which is exactly the intent.
 *  2. **It must contain `success`.** `classify_response` returns
 *     `:schema_invalid` for a 200 whose body fails the definition's response
 *     schema, and that alerts. `success` is the schema's only required
 *     property.
 *
 * Because the neutral body is identical to the genuine "regular customer, no
 * special pricing needed" answer, this route is NOT an oracle for token
 * validity. The genuine PREFERRED answer differs — it carries `metadata` — but
 * reaching it requires a real preferred customer, not a probe.
 *
 * The status code therefore tells an operator nothing here. The
 * `[fluid-callback:cart-email-on-create] rejected` log line is the only signal,
 * and is what an alert should be built on.
 */

import { NextResponse } from "next/server";

import {
  callbackRoute,
  cartEmailOnCreate,
  requireEmailOnCreateShape,
} from "@/lib/pricing";

/** The single neutral body this route ever returns when it is not preferred. */
const neutral = () => NextResponse.json({ success: true });

export const POST = callbackRoute({
  definition: "cart_email_on_create",
  name: "cart-email-on-create",
  // The only one of the nine that does NOT require `cart.cart_token`: a cart
  // being created may not have one yet.
  parse: requireEmailOnCreateShape,
  run: cartEmailOnCreate,
  neutral,
});
