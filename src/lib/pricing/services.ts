/**
 * The nine callback services.
 *
 * One function per Fluid callback definition, each a port of the matching
 * `app/services/callbacks/*_service.rb`. They take a `PricingContext` (the port
 * of `Callbacks::BaseService`) and return the body the route answers with.
 *
 * Two Ruby facts that shape the file:
 *
 *  - `CartCustomerAttachedService < CustomerLoggedInService`, overriding ONLY
 *    `customer_email` to fall back to the payload's bound `customer` object.
 *    Here that is `cartCustomerLoggedIn(ctx, email)` with the email passed in.
 *  - Every service rescues `CallbackError` into `{success:false, message:...}`.
 *    Four of them ALSO rescue StandardError; the other five let it escape to
 *    the controller, which answered 500. That asymmetry is real and is kept —
 *    see the per-route failure policy in the route files.
 */

import { field, isBlank, isPresent } from "@/lib/ruby";
import { PricingContext } from "./context";
import {
  CallbackError,
  PREFERRED_CUSTOMER_TYPE,
  type CallbackResult,
  type Json,
} from "./types";

const unexpected = (): CallbackResult => ({
  success: false,
  error: "unexpected_error",
  message: "An unexpected error occurred",
});

/**
 * `cart_item_added`.
 *
 * Re-affirms the preferred_customer slug on EVERY item-add, not only the first.
 * The line price and the price_type slug travel on separate, non-atomic
 * channels: the price goes to the cart items while the slug lives in cart
 * metadata and in the callback response. The old code only wrote the slug when
 * the cart was not yet preferred, so a later item-add on an already-preferred
 * cart repriced the line but left the slug unwritten — and any order whose last
 * cart event was an item-add kept the subscription price with a retail
 * price_type.
 */
export async function cartItemAdded(
  ctx: PricingContext,
): Promise<CallbackResult> {
  try {
    if (isBlank(ctx.cart)) throw new CallbackError("Cart is blank");
    if (ctx.callbackCartItems.length === 0) {
      throw new CallbackError("Cart item is blank");
    }

    if (ctx.cartSettled) return ctx.resultSuccess();
    if (ctx.yieldsToWholesaleDroplet) return ctx.resultSuccess();

    const currentPriceType = ctx.currentPriceType;

    // Preferred pricing applies when the cart is already stamped, OR when it
    // qualifies now. Re-deriving here means a preferred customer still gets the
    // discount when the stamp is missing on this payload — e.g. the cart was
    // emptied then re-added — without depending on attach/login re-firing
    // (STU2-2531).
    if (
      currentPriceType !== PREFERRED_CUSTOMER_TYPE &&
      !(await ctx.cartQualifiesForPreferredPricing())
    ) {
      return {
        success: true,
        message: "Cart does not have preferred_customer pricing",
      };
    }

    await ctx.updateItemToSubscriptionPrice();
    await ctx.updateCartMetadata({ price_type: PREFERRED_CUSTOMER_TYPE });

    if (currentPriceType !== PREFERRED_CUSTOMER_TYPE) {
      await ctx.logCartPricingEvent({
        eventType: "item_added",
        preferredApplied: true,
        additionalData: {
          item_ids: ctx.callbackCartItems.map((item) => field(item, "id")),
          subscription_price: field(ctx.cartItem, "subscription_price"),
          regular_price: field(ctx.cartItem, "price"),
        },
      });
    }

    return ctx.preferredPricingResponse(
      "Cart item updated to subscription price successfully",
    );
  } catch (error) {
    if (error instanceof CallbackError) {
      return ctx.handleCallbackError(error, "CartItemAddedService");
    }
    ctx.deps.log.error(
      `Unexpected error in CartItemAddedService: ${describe(error)}`,
    );
    ctx.reportException(error);
    return unexpected();
  }
}

/** `cart_item_updated`. Same widened gate as `cart_item_added`. */
export async function cartItemUpdated(
  ctx: PricingContext,
): Promise<CallbackResult> {
  try {
    if (isBlank(ctx.cart)) throw new CallbackError("Cart is blank");
    if (isBlank(ctx.cartItem)) throw new CallbackError("Cart item is blank");

    if (ctx.cartSettled) return ctx.resultSuccess();
    if (ctx.yieldsToWholesaleDroplet) return ctx.resultSuccess();

    const currentPriceType = ctx.currentPriceType;

    if (
      currentPriceType !== PREFERRED_CUSTOMER_TYPE &&
      !(await ctx.cartQualifiesForPreferredPricing())
    ) {
      return {
        success: true,
        message: "Cart does not have preferred_customer pricing",
      };
    }

    await ctx.updateItemToSubscriptionPrice();
    await ctx.updateCartMetadata({ price_type: PREFERRED_CUSTOMER_TYPE });

    return ctx.preferredPricingResponse(
      "Item updated callback processed successfully",
    );
  } catch (error) {
    if (error instanceof CallbackError) {
      return ctx.handleCallbackError(error, "CartItemUpdatedService");
    }
    ctx.deps.log.error(
      `Unexpected error in CartItemUpdatedService: ${describe(error)}`,
    );
    ctx.reportException(error);
    return unexpected();
  }
}

/** `cart_subscription_added`. */
export async function subscriptionAdded(
  ctx: PricingContext,
): Promise<CallbackResult> {
  try {
    if (isBlank(ctx.cart)) throw new CallbackError("Cart is blank");

    if (ctx.cartSettled) return ctx.resultSuccess();
    if (ctx.yieldsToWholesaleDroplet) return ctx.resultSuccess();

    const currentPriceType = ctx.currentPriceType;

    await ctx.updateCartMetadata({ price_type: PREFERRED_CUSTOMER_TYPE });
    if (ctx.cartItems.length > 0) {
      await ctx.updateCartItemsPrices(await ctx.cartItemsWithSubscriptionPrice());
      await ctx.updateCartItemsVolumes(ctx.cartItems, "subscription");
    }

    if (currentPriceType !== PREFERRED_CUSTOMER_TYPE) {
      await ctx.logCartPricingEvent({
        eventType: "item_added",
        preferredApplied: true,
        additionalData: {
          callback: "subscription_added",
          items_updated: ctx.cartItems.length,
        },
      });
    }

    return ctx.resultSuccess();
  } catch (error) {
    if (error instanceof CallbackError) {
      return ctx.handleCallbackError(error, "SubscriptionAddedService");
    }
    throw error;
  }
}

/** `cart_subscription_removed`. */
export async function subscriptionRemoved(
  ctx: PricingContext,
): Promise<CallbackResult> {
  try {
    if (isBlank(ctx.cart)) throw new CallbackError("Cart is blank");

    if (ctx.cartSettled) return ctx.resultSuccess();
    if (ctx.yieldsToWholesaleDroplet) return ctx.resultSuccess();

    const currentPriceType = ctx.currentPriceType;
    const wasPreferred = currentPriceType === PREFERRED_CUSTOMER_TYPE;

    if (isBlank(ctx.customerEmail)) {
      if (ctx.hasAnotherSubscriptionInCart) {
        await ctx.updateCartMetadata({ price_type: PREFERRED_CUSTOMER_TYPE });
        if (ctx.cartItems.length > 0) {
          await ctx.updateCartItemsPrices(
            await ctx.cartItemsWithSubscriptionPrice(),
          );
          await ctx.updateCartItemsVolumes(ctx.cartItems, "subscription");
        }
        return ctx.resultSuccess();
      }

      await ctx.updateCartMetadata({ price_type: null });
      if (ctx.cartItems.length > 0) {
        await ctx.updateCartItemsPrices(await ctx.cartItemsWithRegularPrice());
        await ctx.updateCartItemsVolumes(ctx.cartItems, "regular");
      }

      if (wasPreferred) {
        await ctx.logCartPricingEvent({
          eventType: "item_updated",
          preferredApplied: false,
          additionalData: {
            callback: "subscription_removed",
            reason: "no_subscriptions_no_email",
          },
        });
      }
      return ctx.resultSuccess();
    }

    const useSubscriptionPrices = await shouldKeepSubscriptionPrices(
      ctx,
      ctx.customerEmail,
    );
    await ctx.updateCartMetadata({
      price_type: useSubscriptionPrices ? PREFERRED_CUSTOMER_TYPE : null,
    });

    if (ctx.cartItems.length > 0) {
      const itemsData = useSubscriptionPrices
        ? await ctx.cartItemsWithSubscriptionPrice()
        : await ctx.cartItemsWithRegularPrice();
      await ctx.updateCartItemsPrices(itemsData);
      await ctx.updateCartItemsVolumes(
        ctx.cartItems,
        useSubscriptionPrices ? "subscription" : "regular",
      );
    }

    if (wasPreferred !== useSubscriptionPrices) {
      await ctx.logCartPricingEvent({
        eventType: "item_updated",
        preferredApplied: useSubscriptionPrices,
        additionalData: {
          callback: "subscription_removed",
          reason: useSubscriptionPrices
            ? "should_keep_preferred"
            : "removed_preferred",
        },
      });
    }

    return ctx.resultSuccess();
  } catch (error) {
    if (error instanceof CallbackError) {
      return ctx.handleCallbackError(error, "SubscriptionRemovedService");
    }
    throw error;
  }
}

async function shouldKeepSubscriptionPrices(
  ctx: PricingContext,
  customerEmail: string | undefined,
): Promise<boolean> {
  if (isBlank(customerEmail)) return false;
  if (ctx.hasAnotherSubscriptionInCart) return true;
  if (!ctx.customerLoggedIn) return false;

  const customerId = await ctx.getCustomerIdByEmail(customerEmail);
  if (isPresent(customerId)) {
    if (await ctx.hasActiveSubscriptions(customerId)) return true;
    if (
      (await ctx.getCustomerTypeFromMetafields(customerId)) ===
      PREFERRED_CUSTOMER_TYPE
    ) {
      return true;
    }
  }

  return ctx.exigoPreferredByEmail(customerEmail);
}

/**
 * `cart_email_on_create`.
 *
 * THE ONE ROUTE WHOSE RESPONSE FLUID APPLIES BACK TO THE CART.
 * `Commerce::Carts::CreateAction#enrich_cart_metadata` merges
 * `response.metadata` into `cart.metadata` with `update_column`, and skips the
 * response entirely unless `response.success?`. Two consequences the route file
 * depends on:
 *
 *  - a non-2xx here silently drops the cart's price_type stamp, so this route
 *    fails OPEN, and
 *  - the neutral body must NOT carry `metadata`, or an auth failure would stamp
 *    preferred pricing onto a cart that has not earned it.
 *
 * The "regular customer" body at the bottom is that neutral body.
 */
export async function cartEmailOnCreate(
  ctx: PricingContext,
): Promise<CallbackResult> {
  try {
    if (isBlank(ctx.cart)) throw new CallbackError("Cart is blank");

    const email = ctx.customerEmail;
    if (isBlank(email)) throw new CallbackError("Email is blank");

    const currentPriceType = ctx.currentPriceType;
    const preferred =
      ctx.customerLoggedIn && (await ctx.isPreferredCustomer(email));

    if (preferred) {
      await syncPccMetafield(ctx, ctx.cartCustomerId, "CartEmailOnCreate");

      if (currentPriceType !== PREFERRED_CUSTOMER_TYPE) {
        await ctx.logCartPricingEvent({
          eventType: "cart_created",
          preferredApplied: true,
          additionalData: { email },
        });
      }
      // The genuine preferred answer, which IS the metadata-carrying one.
      return {
        success: true,
        metadata: { price_type: PREFERRED_CUSTOMER_TYPE },
      };
    }

    if (currentPriceType === PREFERRED_CUSTOMER_TYPE) {
      await ctx.logCartPricingEvent({
        eventType: "cart_created",
        preferredApplied: false,
        additionalData: { email },
      });
    }

    return { success: true, message: "Regular customer, no special pricing needed" };
  } catch (error) {
    if (error instanceof CallbackError) {
      return ctx.handleCallbackError(error, "CartEmailOnCreateService");
    }
    ctx.deps.log.error(`Error in CartEmailOnCreateService: ${describe(error)}`);
    // Rails re-raised here, and the controller answered 500. The route turns
    // that into its neutral 200 — see the route file for why.
    throw error;
  }
}

/**
 * `cart_customer_logged_in`, and — with `email` overridden — `cart_customer_attached`.
 *
 * `cart_customer_attached` is the high-traffic one: its `order_completion`
 * trigger is roughly 39% of its volume, and that trigger fires while the
 * subscription-start order is being finalised.
 */
export async function customerLoggedIn(
  ctx: PricingContext,
  email: string | undefined = ctx.customerEmail,
  serviceName = "CustomerLoggedInService",
): Promise<CallbackResult> {
  try {
    if (isBlank(ctx.cart)) throw new CallbackError("Cart is blank");
    if (isBlank(email)) throw new CallbackError("Email is blank");
    if (!ctx.customerLoggedIn) {
      throw new CallbackError("Customer is not logged in");
    }

    // Checked BEFORE the lookups below so those carts still cost no API calls.
    if (ctx.yieldsToWholesaleDroplet) return ctx.resultSuccess();

    const isPreferred = await ctx.isPreferredCustomer(email);
    const currentPriceType = ctx.currentPriceType;

    // customer_type is a CUSTOMER resource, not a cart one, so the settled-cart
    // guard below does not apply to it. Kept ABOVE the guard: order_completion
    // is ~39% of cart_customer_attached traffic and is the moment a
    // guest-checkout customer first exists, so gating this would delay the
    // stamp on most guest orders for no safety gain (CURRENT-3361).
    if (isPreferred) {
      await syncPccMetafield(ctx, ctx.cartCustomerId, "CustomerLoggedIn");
    }

    // Everything past here writes to the cart, or claims a cart state that no
    // longer exists.
    if (ctx.cartSettled) return ctx.resultSuccess();

    if (isPreferred) {
      await ctx.updateCartMetadata({ price_type: PREFERRED_CUSTOMER_TYPE });
      if (ctx.cartItems.length > 0) {
        await ctx.updateCartItemsPrices(
          await ctx.cartItemsWithSubscriptionPrice(),
        );
        await ctx.updateCartItemsVolumes(ctx.cartItems, "subscription");
      }

      if (currentPriceType !== PREFERRED_CUSTOMER_TYPE) {
        await ctx.logCartPricingEvent({
          eventType: "customer_logged_in",
          preferredApplied: true,
          additionalData: { email, customer_id: ctx.cartCustomerId },
        });
      }

      return {
        success: true,
        metadata: { price_type: PREFERRED_CUSTOMER_TYPE },
      };
    }

    // `isPreferred === false` can mean "not preferred" or "we could not tell":
    // every lookup behind isPreferredCustomer rescues to false. ONLY the former
    // justifies stripping the discount off every line (CURRENT-3361).
    if (
      currentPriceType === PREFERRED_CUSTOMER_TYPE &&
      !ctx.hasAnotherSubscriptionInCart &&
      !ctx.preferredLookupFailed
    ) {
      await ctx.updateCartMetadata({ price_type: null });
      if (ctx.cartItems.length > 0) {
        await ctx.updateCartItemsPrices(await ctx.cartItemsWithRegularPrice());
        await ctx.updateCartItemsVolumes(ctx.cartItems, "regular");
      }

      await ctx.logCartPricingEvent({
        eventType: "customer_logged_in",
        preferredApplied: false,
        additionalData: {
          email,
          customer_id: ctx.cartCustomerId,
          reason: "not_preferred",
        },
      });
    }

    return ctx.resultSuccess();
  } catch (error) {
    if (error instanceof CallbackError) {
      return ctx.handleCallbackError(error, serviceName);
    }
    ctx.deps.log.error(`Error in ${serviceName}: ${describe(error)}`);
    ctx.reportException(error);
    return unexpected();
  }
}

/**
 * `cart_customer_attached` — fires whenever a customer becomes bound to a cart
 * (cart_create, session_inherited, checkout_entry, magic_link, mfa_login,
 * order_completion), including the "already logged in, entering the new
 * checkout" case that `cart_customer_logged_in` never covered (STU2-2531).
 *
 * The pricing behaviour is IDENTICAL to `customerLoggedIn`; the only difference
 * is that this payload ships the bound `customer` object, so its email is the
 * fallback when the cart itself does not carry one yet.
 */
export async function cartCustomerAttached(
  ctx: PricingContext,
): Promise<CallbackResult> {
  const fromCart = ctx.customerEmail;
  const email = isPresent(fromCart)
    ? fromCart
    : (field<string>(ctx.params.customer as Json | undefined, "email") ??
      undefined);

  return customerLoggedIn(ctx, email, "CartCustomerAttachedService");
}

/**
 * `cart_customer_detached` — a logout, back to guest.
 *
 * Rolls back ONLY pricing this droplet actually applied. An unstamped cart was
 * never put on preferred pricing by us, so rewriting every line to
 * product.price on a mere logout would clobber whatever else set those prices
 * (another droplet, a promo) — and was one half of the oscillating pair in
 * CURRENT-3361. That guard must not be simplified away.
 */
export async function cartCustomerDetached(
  ctx: PricingContext,
): Promise<CallbackResult> {
  try {
    if (isBlank(ctx.cart)) throw new CallbackError("Cart is blank");

    if (ctx.cartSettled) return ctx.resultSuccess();
    if (ctx.yieldsToWholesaleDroplet) return ctx.resultSuccess();

    const wasPreferred = ctx.currentPriceType === PREFERRED_CUSTOMER_TYPE;

    if (ctx.hasAnotherSubscriptionInCart) {
      await ctx.updateCartMetadata({ price_type: PREFERRED_CUSTOMER_TYPE });
      if (ctx.cartItems.length > 0) {
        await ctx.updateCartItemsPrices(
          await ctx.cartItemsWithSubscriptionPrice(),
        );
        await ctx.updateCartItemsVolumes(ctx.cartItems, "subscription");
      }
      return ctx.resultSuccess();
    }

    if (!wasPreferred) return ctx.resultSuccess();

    await ctx.updateCartMetadata({ price_type: null });
    if (ctx.cartItems.length > 0) {
      await ctx.updateCartItemsPrices(await ctx.cartItemsWithRegularPrice());
      await ctx.updateCartItemsVolumes(ctx.cartItems, "regular");
    }

    await ctx.logCartPricingEvent({
      eventType: "customer_detached",
      preferredApplied: false,
      additionalData: { callback: "cart_customer_detached" },
    });

    return ctx.resultSuccess();
  } catch (error) {
    if (error instanceof CallbackError) {
      return ctx.handleCallbackError(error, "CartCustomerDetachedService");
    }
    throw error;
  }
}

/**
 * `cart_country_changed` — repairs the cart lines this droplet LOCKED when the
 * cart's country changes.
 *
 * Every price the droplet writes gets `metadata.price_locked` stamped on it,
 * and Fluid skips locked lines when it reprices, so a line written under the
 * old country keeps its amount while the currency around it changes. Releasing
 * the lock is not the answer — Fluid would recompute from the catalog and drop
 * the preferred-customer discount this droplet exists to apply. The writer is
 * the only one who can correct a locked line.
 */
export async function cartCountryChanged(
  ctx: PricingContext,
): Promise<CallbackResult> {
  try {
    if (isBlank(ctx.cart)) throw new CallbackError("Cart is blank");

    if (ctx.cartSettled) return ctx.resultSuccess();
    if (ctx.yieldsToWholesaleDroplet) return ctx.resultSuccess();

    // Only the lines this droplet locked. Everything else core has already
    // repriced at the new country, and writing to it would lock a price Fluid
    // set itself.
    const locked = ctx.lockedCartItems;
    if (locked.length === 0) return ctx.resultSuccess();

    // Same gate as the item callbacks. It picks WHICH price to restore, not
    // whether to act — a detached cart still carries lines this droplet locked
    // at retail, and those strand on a country change exactly like the
    // preferred ones.
    const preferred =
      ctx.currentPriceType === PREFERRED_CUSTOMER_TYPE ||
      (await ctx.cartQualifiesForPreferredPricing());

    if (preferred) {
      await ctx.updateCartItemsPrices(
        await ctx.cartItemsWithSubscriptionPrice(locked),
      );
      await ctx.updateCartItemsVolumes(locked, "subscription");
    } else {
      await ctx.updateCartItemsPrices(
        await ctx.cartItemsWithRegularPrice(locked),
      );
      await ctx.updateCartItemsVolumes(locked, "regular");
    }

    await ctx.logCartPricingEvent({
      eventType: "country_changed",
      preferredApplied: preferred,
      additionalData: {
        callback: "cart_country_changed",
        country_code:
          field(ctx.callbackContext, "country_code") ?? ctx.cartCountry,
        previous_country_code: field(
          ctx.callbackContext,
          "previous_country_code",
        ),
        items_updated: locked.length,
      },
    });

    return preferred
      ? ctx.preferredPricingResponse("Cart repriced for the new country")
      : ctx.successWithMessage("Cart repriced for the new country");
  } catch (error) {
    if (error instanceof CallbackError) {
      return ctx.handleCallbackError(error, "CartCountryChangedService");
    }
    throw error;
  }
}

/**
 * Writes the preferred_customer metafield, unless it already says so.
 *
 * The metafield is the EXIGO source's cache. An installation reading Fluid
 * member types no longer consults it, so writing it would keep a value nothing
 * reads up to date at the cost of Fluid calls on a callback.
 */
async function syncPccMetafield(
  ctx: PricingContext,
  customerId: unknown,
  logPrefix: string,
): Promise<void> {
  try {
    if (isBlank(customerId)) return;
    if (ctx.settings.preferredFromFluidMemberType) return;

    const currentType = await ctx.getCustomerTypeFromMetafields(customerId);
    if (currentType === PREFERRED_CUSTOMER_TYPE) return;

    await ctx.updatePccMetafield(customerId, PREFERRED_CUSTOMER_TYPE);
    ctx.deps.log.info(
      `[${logPrefix}] Updated PCC metafield to preferred_customer for customer ${String(customerId)}`,
    );
  } catch (error) {
    ctx.deps.log.error(
      `[${logPrefix}] Failed to sync PCC metafield: ${describe(error)}`,
    );
  }
}

function describe(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
