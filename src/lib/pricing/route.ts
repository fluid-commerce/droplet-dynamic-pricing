/**
 * The shared shape of a callback route.
 *
 * Port of `Callbacks::BaseController`: parse, run the service, answer 200 on
 * success and 400 on a service-level failure, and emit ONE greppable timing
 * line per request. Authentication is the part that is not a port — Rails had
 * none at all (`Callbacks::BaseController` has no `before_action`, and the
 * tenant came from `cart.company.id` in the body) — so it is delegated to the
 * SDK's `withFluidCallback` and the tenant comes from the verified
 * registration, never from the payload.
 *
 * ## Failure policy: eight routes fail CLOSED, one fails OPEN
 *
 * The fleet's usual rule — "a callback must always answer 200, because a 401 is
 * a broken cart" — is FALSE for eight of this droplet's nine, and it was
 * checked in fluid's source rather than assumed:
 *
 *  - `Callback::Client.request` does not raise on a non-2xx; a real response of
 *    any status becomes a Data object and is handed back to the caller.
 *  - Eight of the nine callers DISCARD that value. `CartItemCallbackSubscriber#deliver`
 *    calls `Callback::Client.request(...)` as a statement;
 *    `UpdateCountryAction` uses `notify`, which is async and never sees a
 *    response at all. The cart outcome is identical whether we refuse or answer
 *    a neutral 200: the droplet did not reprice, so the shopper pays retail.
 *  - A non-2xx is the ONLY thing that produces an operator signal.
 *    `classify_response` marks it `:http_error` and `report_failure` raises a
 *    Sentry event and a `wecommerce_errors` Slack message. A 200 neutral body
 *    produces silence — and silence is exactly the failure mode that let these
 *    callbacks run unauthenticated for a year.
 *
 * So eight routes pass NO `on*` overrides and inherit the SDK's 401/400/500.
 * The ninth, `cart_email_on_create`, is the one whose response Fluid applies
 * back to the cart, and it overrides all three. See its route file.
 */

import { withFluidCallback } from "@fluid-app/droplet-sdk/next";
import { NextResponse } from "next/server";

import { callbackStore, resolvePrincipal } from "@/lib/callbacks";
import type { PricingContext } from "./context";
import { buildPricingContext } from "./runtime";
import { MissingParameterError } from "./validate";
import type { CallbackParams, CallbackResult } from "./types";

export interface CallbackRouteConfig {
  /** The FLUID definition name — the filename in app/lib/callback_definitions. */
  definition: string;
  /** The kebab log/route name. Matches the URL segment. */
  name: string;
  /** Validates and narrows the body, exactly as the Rails controller did. */
  parse: (payload: unknown) => CallbackParams;
  run: (ctx: PricingContext) => Promise<CallbackResult>;
  /**
   * Supplied ONLY by a route that must fail open. When present it is used for
   * auth failures, invalid bodies, handler errors AND service-level failures,
   * so that all four are byte-identical and the route is not an oracle for
   * token validity.
   */
  neutral?: () => NextResponse;
}

/**
 * One line per callback, in the shape the Rails controller emitted.
 *
 * These are the requests a shopper's add-to-cart is blocked on. Best-effort by
 * construction: instrumentation must never be the reason a callback fails.
 */
function logTiming(
  name: string,
  startedAt: number,
  outcome: string,
  cartToken?: unknown,
): void {
  try {
    console.log(
      `[DynamicPricing] marker=callback-timing callback=${name} ` +
        `outcome=${outcome} duration_ms=${Math.round(performance.now() - startedAt)} ` +
        `cart=${JSON.stringify(cartToken ?? null)}`,
    );
  } catch (error) {
    console.warn(
      `[DynamicPricing] failed to log callback timing: ${
        error instanceof Error ? error.message : String(error)
      }`,
    );
  }
}

/**
 * Reads the cart token for the timing line without trusting the payload.
 *
 * Deliberately reads the RAW body rather than the validated params, because
 * the invalid-payload path is exactly one of the cases worth timing — that is
 * why the Rails version read `params` and not `permitted_params`.
 */
function cartTokenOf(payload: unknown): unknown {
  if (!payload || typeof payload !== "object") return null;
  const cart = (payload as Record<string, unknown>)["cart"];
  if (!cart || typeof cart !== "object") return null;
  const record = cart as Record<string, unknown>;
  return record["cart_token"] ?? record["token"] ?? null;
}

export function callbackRoute(config: CallbackRouteConfig) {
  const { definition, name, parse, run, neutral } = config;

  const failure = neutral
    ? {
        onAuthFailure: () => {
          logTiming(name, performance.now(), "auth_failed");
          return neutral();
        },
        onInvalidBody: () => neutral(),
        onHandlerError: () => neutral(),
      }
    : {};

  return withFluidCallback(
    {
      definitions: [definition],
      store: callbackStore,
      resolvePrincipal,
      name,
      ...failure,
    },
    async ({ payload, principal: company }) => {
      const startedAt = performance.now();

      let params: CallbackParams;
      try {
        params = parse(payload);
      } catch (error) {
        logTiming(name, startedAt, "invalid_payload", cartTokenOf(payload));
        if (error instanceof MissingParameterError) {
          console.error(`Callback error for ${name}: ${error.message}`);
          if (neutral) return neutral();
          return NextResponse.json(
            { success: false, error: error.message },
            { status: 400 },
          );
        }
        throw error;
      }

      try {
        const ctx = await buildPricingContext(company, params);
        const result = await run(ctx);

        logTiming(
          name,
          startedAt,
          result.success ? "ok" : "rejected",
          cartTokenOf(payload),
        );

        if (result.success) return NextResponse.json(result);
        // Rails answered 400 for a service-level failure. A fail-open route
        // answers its neutral body instead, so that every non-success path
        // looks the same from outside.
        if (neutral) return neutral();
        return NextResponse.json(result, { status: 400 });
      } catch (error) {
        logTiming(name, startedAt, "error", cartTokenOf(payload));
        // The body is never logged: it carries the shopper's email and the
        // whole cart.
        console.error(
          `Callback error for ${name}: ${
            error instanceof Error ? error.message : String(error)
          }`,
        );
        if (neutral) return neutral();
        return NextResponse.json(
          {
            success: false,
            error: error instanceof Error ? error.message : String(error),
          },
          { status: 500 },
        );
      }
    },
  );
}
