/**
 * The routing table this droplet serves, definition name -> URL path.
 *
 * Two of the nine Rails routes were named for something OTHER than their Fluid
 * definition (`/callbacks/subscription_added` serves `cart_subscription_added`,
 * `/callbacks/customer_logged_in` serves `cart_customer_logged_in`), because
 * the Rails path was a LOCAL name an operator typed into the admin Callbacks
 * screen. The Next paths are named for the DEFINITION, kebab-cased, with no
 * exceptions — which is what makes this table mechanical.
 *
 * It is the authority for three things: the URL a registration is created at,
 * the check that refuses to register a callback this app cannot answer (the
 * port of `Callback.serves?`), and the mapping in CUTOVER.md.
 */
export const CALLBACK_ROUTES: Readonly<Record<string, string>> = Object.freeze({
  cart_item_added: "/api/callbacks/cart-item-added",
  cart_item_updated: "/api/callbacks/cart-item-updated",
  cart_subscription_added: "/api/callbacks/cart-subscription-added",
  cart_subscription_removed: "/api/callbacks/cart-subscription-removed",
  cart_email_on_create: "/api/callbacks/cart-email-on-create",
  cart_customer_logged_in: "/api/callbacks/cart-customer-logged-in",
  cart_customer_attached: "/api/callbacks/cart-customer-attached",
  cart_customer_detached: "/api/callbacks/cart-customer-detached",
  cart_country_changed: "/api/callbacks/cart-country-changed",
});

/** The nine definition names, in the order CUTOVER.md lists them. */
export const SERVED_DEFINITIONS = Object.freeze(Object.keys(CALLBACK_ROUTES));

/**
 * The RAILS path each definition is served at today, for the rollback
 * direction.
 *
 * Two of the nine differ from the definition name, and that asymmetry is the
 * whole reason this table exists rather than a string transform:
 * `cart_subscription_added` is served at `/callbacks/subscription_added`, and
 * `cart_customer_logged_in` at `/callbacks/customer_logged_in`. A rollback that
 * derived the Rails path from the definition name would register two of the
 * nine at routes Rails does not have — and because Fluid discards the status of
 * eight of them, the symptom would be "prices are wrong", not an error.
 */
export const RAILS_CALLBACK_PATHS: Readonly<Record<string, string>> =
  Object.freeze({
    cart_item_added: "/callbacks/cart_item_added",
    cart_item_updated: "/callbacks/cart_item_updated",
    cart_subscription_added: "/callbacks/subscription_added",
    cart_subscription_removed: "/callbacks/subscription_removed",
    cart_email_on_create: "/callbacks/cart_email_on_create",
    cart_customer_logged_in: "/callbacks/customer_logged_in",
    cart_customer_attached: "/callbacks/cart_customer_attached",
    cart_customer_detached: "/callbacks/cart_customer_detached",
    cart_country_changed: "/callbacks/cart_country_changed",
  });
