# Cutting the dynamic-pricing droplet over from Rails to Next

Both apps read the same database — the Next app maps onto the Rails tables with
`@@map`, and there is no data migration. What decides which app serves a company
is not a hostname or a load balancer: **Fluid calls whatever url is recorded in
that installation's callback and webhook registrations.** The registration table
is the routing table, and it is keyed per company, per definition.

That is what makes this safe to do one tenant — and one callback — at a time.

The two services:

| | Cloud Run service | Callbacks | Webhooks |
|---|---|---|---|
| Rails | `fluid-droplet-dynamic-pricing` | `POST /callbacks/<local_name>` | `POST /webhook`, `POST /webhook/subscription_*` |
| Next | `fluid-droplet-dynamic-pricing-next` | `POST /api/callbacks/<kebab-definition-name>` | `POST /api/webhooks`, `POST /api/webhooks/subscription-*` |

Both live in `europe-west1`, project `fluid-417204`.

**This droplet has nine callbacks — the most of any in the fleet — and every one
of them sits at a different path in each app.** That is why `scripts/cutover.ts`
takes a `--paths next|rails` direction rather than the single `--callback-path`
flag the template ships with.

---

## 1. The definition-name mapping — verified, not assumed

A Rails callback route name is a LOCAL name. It is whatever an operator typed
into the admin Callbacks screen, and it is frequently *not* the Fluid definition
name. A wrong name means Fluid silently stops calling; nothing errors, and the
symptom is "prices are wrong".

Every one of the nine was checked against
`fluid-workspace/fluid-main/app/lib/callback_definitions/*.yml` at
`d32cd11800` — the filenames in that directory are the complete valid set, and
there are 22 of them.

| # | Rails route (local name) | Fluid `definition_name` | Definition file exists? | Next route |
|---|---|---|---|---|
| 1 | `POST /callbacks/cart_item_added` | `cart_item_added` | ✅ `cart_item_added.yml` | `POST /api/callbacks/cart-item-added` |
| 2 | `POST /callbacks/cart_item_updated` | `cart_item_updated` | ✅ `cart_item_updated.yml` | `POST /api/callbacks/cart-item-updated` |
| 3 | **`POST /callbacks/subscription_added`** | **`cart_subscription_added`** | ✅ `cart_subscription_added.yml` | `POST /api/callbacks/cart-subscription-added` |
| 4 | **`POST /callbacks/subscription_removed`** | **`cart_subscription_removed`** | ✅ `cart_subscription_removed.yml` | `POST /api/callbacks/cart-subscription-removed` |
| 5 | `POST /callbacks/cart_email_on_create` | `cart_email_on_create` | ✅ `cart_email_on_create.yml` | `POST /api/callbacks/cart-email-on-create` |
| 6 | **`POST /callbacks/customer_logged_in`** | **`cart_customer_logged_in`** | ✅ `cart_customer_logged_in.yml` | `POST /api/callbacks/cart-customer-logged-in` |
| 7 | `POST /callbacks/cart_customer_attached` | `cart_customer_attached` | ✅ `cart_customer_attached.yml` | `POST /api/callbacks/cart-customer-attached` |
| 8 | `POST /callbacks/cart_customer_detached` | `cart_customer_detached` | ✅ `cart_customer_detached.yml` | `POST /api/callbacks/cart-customer-detached` |
| 9 | `POST /callbacks/cart_country_changed` | `cart_country_changed` | ✅ `cart_country_changed.yml` | `POST /api/callbacks/cart-country-changed` |

**Three of the nine have a Rails route name that is not the definition name**
(rows 3, 4 and 6, in bold). **Names that do not exist as definitions: none.**

The Next paths are named for the DEFINITION, kebab-cased, with no exceptions —
which is what makes the table in `src/lib/pricing/routes-table.ts` mechanical.
`RAILS_CALLBACK_PATHS` in the same file holds the other direction, and it is a
literal table rather than a string transform precisely because of rows 3, 4 and
6: deriving `/callbacks/cart_subscription_added` from the definition name would
register a route Rails does not have.

**How the mapping was verified.** The `definition_name` sent to Fluid is
`Callback#name` from the `callbacks` table, and those rows are created only by
`CallbackSyncService` from `GET /api/callback/definitions`
(`app/services/callback_sync_service.rb:31`) — so they are constrained to real
definitions by construction. The route each name is served at is
`config/routes.rb:15-25`, and the service each route dispatches to is the
`service_class` in the matching `app/controllers/callbacks/*_controller.rb`. The
definition side was confirmed by listing
`fluid-main/app/lib/callback_definitions/` directly. `verify_email_success` was
served until commit `ad864d5` and is gone; **do not resurrect it.**

### `country_codes` is deliberately omitted at registration

Carried over verbatim, comment included, from
`app/jobs/droplet_installed_job.rb`. Fluid reads `country_codes` as a delivery
FILTER and it is inverted from how it sounds: a dispatch that carries no
country — every `Callback::Client.notify` caller, `cart_country_changed` among
them — matches ONLY registrations whose `country_codes` is empty
(`Callback::Registration.scoped_to_country`). Listing the countries this droplet
prices for would silently stop those callbacks arriving, with no error and
nothing logged.

---

## 2. Webhooks

| `resource.event` | Rails path | Next path | Registered by |
|---|---|---|---|
| `droplet.installed` | `POST /webhook` | `POST /api/webhooks` | the droplet record (`fluid_webhook` setting) |
| `droplet.uninstalled` | `POST /webhook` | `POST /api/webhooks` | the droplet record |
| `subscription.started` | `POST /webhook/subscription_started` | `POST /api/webhooks/subscription-started` | install, per company |
| `subscription.paused` | `POST /webhook/subscription_paused` | `POST /api/webhooks/subscription-paused` | install, per company |
| `subscription.cancelled` | `POST /webhook/subscription_cancelled` | `POST /api/webhooks/subscription-cancelled` | install, per company |
| `subscription.resumed` | `POST /webhook/subscription_resumed` | `POST /api/webhooks/subscription-resumed` | install, per company |
| `subscription.reactivated` | `POST /webhook/subscription_reactivated` | `POST /api/webhooks/subscription-reactivated` | install, per company |
| `subscription.updated` | ❌ registered at `/webhook/cart_item_updated`, a route that never existed | not registered | — |

`subscription.updated` was already removed from the install job on `main`. The
UNINSTALL filter still lists `updated` (`SUBSCRIPTION_CLEANUP_EVENTS`) so that
any registration left over from before is cleaned up rather than left 404ing for
a company that no longer has the droplet.

### The webhook signing key, and its honest limit

Fluid's `Webhook#request_headers` (`fluid app/models/webhook.rb:169-189`) HMACs
`{timestamp}.{body}` with the webhook's stored `auth_token` — and puts that same
value in the `AUTH_TOKEN` and `X-Fluid-Token` headers. There is no separate
signing secret.

Two consequences:

1. **Per-company webhooks are registered with the COMPANY's own
   `webhook_verification_token`**, not the shared one, matching what Rails did.
   The droplet-template registers these with `FLUID_WEBHOOK_AUTH_TOKEN` on the
   reasoning that the verification token should not travel in a header — but
   since the header value IS the HMAC key, using the shared token would mean
   every company's webhooks verify against one droplet-wide value AND Fluid
   would broadcast that value to every tenant. Per-company is strictly better.
2. **The key travels with every delivery**, so a webhook signature here is an
   integrity check on the body rather than proof the caller holds a secret. That
   is Fluid's scheme, not this droplet's choice, and it is recorded rather than
   papered over. It is still a large improvement on what it replaces: Rails
   accepted an `AUTH_TOKEN` header that was `include?`-equal to EITHER the
   company's token OR one droplet-wide value seeded as `"change-me"`, with the
   company taken from the caller's payload.

Lifecycle events (`droplet.installed` / `droplet.uninstalled`) accept the shared
bootstrap secret **and nothing else** — a company token cannot sign one. The
subscription routes pass no `bootstrapSecret` at all.

---

## 3. Failure policy: eight closed, one open

This is the item most likely to be got wrong by copying another droplet, and it
was settled against fluid's source rather than assumed.

`Callback::Client.request` does not raise on a non-2xx; a real response of any
status becomes a `Data` object and is handed back to the caller. What matters is
what the caller does with it:

| Definition | Dispatched by | Response read? | Policy here |
|---|---|---|---|
| `cart_item_added` | `CartItemCallbackSubscriber#deliver` | no — discarded | **closed** |
| `cart_item_updated` | same | no | **closed** |
| `cart_subscription_added` | same, + `ManageSubscriptionAction` | no | **closed** |
| `cart_subscription_removed` | `ManageSubscriptionAction` | no | **closed** |
| `cart_customer_attached` | `CartCustomerCallbackSubscriber` | no | **closed** |
| `cart_customer_detached` | same | no | **closed** |
| `cart_customer_logged_in` | `Commerce::Cart#trigger_customer_logged_in_callback` | no | **closed** |
| `cart_country_changed` | `UpdateCountryAction#notify_country_changed` — **`notify`, async** | no | **closed** |
| **`cart_email_on_create`** | `CreateAction#request_email_callback` | **YES** | **open** |

**The eight closed routes pass no `on*` overrides at all** and inherit the SDK's
401 / 400 / 500. The reasoning:

- The cart outcome is identical either way. A refused request means the droplet
  did not reprice; so does a 200 neutral body. The shopper pays retail in both.
- A non-2xx is the ONLY thing that produces an operator signal. Fluid's
  `classify_response` marks it `:http_error` and `report_failure` raises a
  Sentry event and a `wecommerce_errors` Slack message. A 200 neutral body is
  silence — and silence is exactly the failure mode that let these callbacks run
  unauthenticated for a year.

**`cart_email_on_create` fails open**, with the body `{"success": true}` —
byte-identical across the auth-failure, invalid-body, handler-error and
legitimate "regular customer" paths.
`Commerce::Api::Carts::CreateAction#enrich_cart_metadata` merges
`response.metadata` into `cart.metadata` with `update_column`, and skips the
response entirely unless `response.success?`, which is `Typhoeus::Response#success?`
— the HTTP STATUS. So a non-2xx there silently drops the cart's `price_type`
stamp.

Two constraints on that body, both asserted in
`src/app/api/callbacks/cart-email-on-create/route.test.ts`:

1. **It must not contain `metadata`,** or an auth failure would stamp preferred
   pricing onto a cart that has not earned it.
2. **It must contain `success`,** or `classify_response` returns
   `:schema_invalid` and alerts.

Because the neutral body is identical to the genuine "regular customer" answer,
the route is not an oracle for token validity.

**Response body keys are restricted to `success` / `message` / `metadata` /
`error`.** `build_response_data` does `Data.define(*payload.keys)`; a key that is
not a valid Ruby identifier raises `NameError` inside `request.on_complete`,
which escapes `hydra.run` and is not caught by the subscribers' rescue.

### Latency, not status, is the shared risk

Eight of the nine are dispatched synchronously on the shopper's request thread
with a 20-second ceiling. Watch p95, not just error rate, during phases 3 and 4
below. The engine emits one `marker=callback-timing` line per request with
`callback`, `outcome`, `duration_ms` and `cart`, and
`src/lib/pricing/deps.ts` exists so a test can assert call COUNTS as well as
outcomes.

---

## 4. Why not a percentage split

A split sends one add-to-cart to Rails and the next to Next for the same cart.
Both apps decide independently whether the cart is preferred, and both write
prices Fluid then LOCKS — so a shopper can end up with half a cart at
subscription prices and half at retail, with no error on either side.

And webhooks are at-least-once with per-app idempotency. Two apps behind one url
both act on the same `subscription.cancelled`: two demotions, two transaction
rows. Nothing deduplicates across the app boundary because neither app knows the
other exists.

Per-company, per-definition cutover has a blast radius of one tenant, an instant
rollback, and no double-processing.

---

## 5. The sequence

**0. Run the Rails migration.** `fluid_callback_registrations` is created by
`db/migrate/20260903000001_create_fluid_callback_registrations.rb`, which the
existing `${_APP_NAME}-migrations` Cloud Run job runs as part of the ordinary
Rails deploy. **This must happen before anything else.** A table that exists
only as a Prisma model exists nowhere at all: the token lookup raises, the SDK
reads a raising store as an auth failure, and every genuine callback is refused
— behind a 401 on eight routes and behind a silent 200 on the ninth.

Verify: `SELECT to_regclass('fluid_callback_registrations');` is not null.

**1. Deploy.** Run the `deploy next` workflow. It builds `Dockerfile.next` and
updates the `fluid-droplet-dynamic-pricing-next` Cloud Run service. Nothing
points at it, so this changes nothing — that is the property worth having.

The service is created **once, by hand**, before the first run:
`cloudbuild-next.yml` does `run services update`, not `deploy`, so it cannot
invent configuration. It needs the same `DATABASE_URL` as the Rails service,
plus its own `FLUID_DROPLET_URL`, `AUTH_SECRET` and `FLUID_WEBHOOK_AUTH_TOKEN`.
See `.env.example`. **There are no Exigo environment variables** — every Exigo
credential is per company, in `integration_settings.credentials`.

On boot the app logs whether `fluid_callback_registrations` is populated
(`src/instrumentation.ts` → `reportCallbackVerificationReadiness`). Read that
line before going further.

**2. Smoke.** `scripts/smoke-next.sh <url>`. Unlike the fleet's usual smoke test,
this one has teeth on the callbacks too: eight of the nine fail closed, so an
unsigned probe must come back 401 and a missing route shows up as a 404. Only
`cart-email-on-create` is opaque to an unsigned probe, and that one is checked
for its exact neutral body.

**3. One internal installation, `cart_country_changed` only.** The safest of the
nine, and the reason is structural: `UpdateCountryAction` dispatches it with
`notify`, so it runs on a thread pool and its response is never read — not even
on the shopper's request thread. It fires only on a real country transition and
touches only lines this droplet locked.

```bash
pnpm cutover status  acme                                        # read-only
pnpm cutover repoint acme --url https://...-next-...run.app \
                          --from https://fluid-droplet-dynamic-pricing-...run.app
APPLY=1 pnpm cutover repoint acme --url https://...-next-...run.app \
                          --from https://fluid-droplet-dynamic-pricing-...run.app
pnpm cutover status  acme                                        # confirm
```

`--paths` defaults to `next`, so going forwards needs no flag. Going back needs
`--paths rails` — see the rollback below.

Verify: the `[fluid-callback:cart-country-changed] rejected` log line never
appears; a country change on a cart with locked lines produces the same
`update_cart_items_prices` payload the Rails app produced; `cart_pricing_events`
rows with `event_type: "country_changed"` keep appearing. Hold a week.

**4. `cart_email_on_create` and the three customer-lifecycle callbacks.**

`cart_email_on_create` (fail OPEN), then `cart_customer_logged_in`,
`cart_customer_attached`, `cart_customer_detached` (fail closed).
`cart_customer_attached` is the high-traffic one — its `order_completion`
trigger is roughly 39% of its volume.

Verify: for a test company, a cart created with a preferred customer's email
still receives `metadata.price_type = "preferred_customer"` — check
`carts.metadata` in Fluid, not the droplet's logs, because this is the
response-consuming path. A logout on a stamped cart restores retail prices and
clears the stamp. Diff `cart_pricing_events` volumes against the prior week.

**5. The four item and subscription callbacks. The dangerous ones.**

`cart_item_added`, `cart_item_updated`, `cart_subscription_added`,
`cart_subscription_removed` — these reprice every line on every add-to-cart.

Cut over **one definition at a time, one company at a time**, starting with the
lowest-volume installation. Hold a full business day between each.

Verify per definition: the distribution of `cart_pricing_events.cart_total` and
`preferred_pricing_applied` matches the prior week for the same company; zero
`[fluid-callback:…] rejected` lines; zero `Refusing to set zero price` warnings
Rails did not also produce; zero `CrossCountryPriceError` reports Rails did not
also produce; p95 callback latency no worse than the Rails baseline. **Roll back
by re-pointing the registration** — the Rails app is still running and still
correct.

**6. Move the webhooks and the callback configuration.**

`cutover repoint` moves one company's registrations. It does NOT move:

- the droplet-level lifecycle registrations, `droplet.installed` and
  `droplet.uninstalled`, which live on the droplet record rather than on any
  installation; or
- the `callbacks` table rows a NEW installation registers from.

Nothing surfaces either. Every company can be fully cut over and working while
the next install still goes to Rails and registers its callbacks back onto
Rails.

So, once every company has been repointed:

1. In Fluid's droplet settings, set `fluid_webhook.url` to
   `https://…-next-….run.app/api/webhooks` and press **Update Droplet**.
   Confirm an install arrives.
2. On the admin **Callbacks** screen, change each of the nine rows' url to the
   Next path from the table in §1. `pnpm cutover status <shop>` prints these
   rows and flags any still on a Rails path.

Both are global, not per-tenant, and there is no partial version of either.

**7. Retire Rails.** Min-instances to 0 first and leave it a while — that is
reversible in seconds. Delete only once nothing has needed it.

---

## 6. Rollback

```bash
APPLY=1 pnpm cutover repoint acme \
  --url  https://fluid-droplet-dynamic-pricing-...run.app \
  --from https://fluid-droplet-dynamic-pricing-next-...run.app \
  --paths rails
```

`--paths rails` is REQUIRED going back and the tool will not guess the
direction. Without it the rollback would register every definition at the Next
path on the Rails host — routes Rails does not have — and for eight of the nine
the symptom would be a silently missing reprice rather than an error anyone
sees. The three definitions whose Rails path is not their definition name (§1,
rows 3, 4 and 6) make a hand-written rollback particularly easy to get wrong,
which is why the paths live in a table rather than in the command.

The repoint is an **update in place**, not a delete-then-create, and that is
load-bearing. Fluid sets `verification_token` in `before_create` and never
rotates it, `UpdateAction` accepts `url`, and `api_show` renders the `:shared`
view which still carries the token. So the registration keeps its uuid and its
token while only the url moves, and the tool reads the token back afterwards to
store its digest. There is no window where a definition has no registration and
Fluid quietly stops calling.

`--from` is only a hint: it lets the tool recognise a registration as ours
before we hold any digest for it, which is the state every company is in on its
first cutover. Where more than one registration could plausibly be ours, the
tool stops and prints them rather than guessing — the listing is company-scoped,
so another droplet installed for the same company can hold a registration with
the same `definition_name`.

**If a repoint fails halfway**, read which of two things happened:

*The url moved but the token was not stored.* The failure message names the
definition. Only the digest is missing:

```bash
APPLY=1 pnpm cutover reconcile acme --url https://...-next-...run.app
```

*A later update failed outright.* Then some registrations are at one url and
some at the other. `reconcile` will NOT fix this and will report "Nothing to
fix". Either finish the move by re-running the repoint, or put everything back
with the rollback command above. The failure message prints the exact rollback
command, including `--paths`, along with everything it had already moved.

---

## 7. Rules while both apps are live

**Rails owns the schema.** Two migration tools against one database produces a
schema neither app agrees with. `cloudbuild-next.yml` has no migrations step and
must not gain one; the `fluid-droplet-dynamic-pricing-migrations` Cloud Run job
stays the Rails pipeline's. `prisma/schema.prisma` pins every index to its Rails
name with `map:` so that `prisma migrate diff` is clean — but **`pnpm db:push`
is not guarded**, and it would happily reshape a live Rails schema. Treat that
command as unavailable during a cutover window.

**No encrypted columns.** This droplet uses none, so the usual trap — Prisma
reading the base64 envelope of a Rails `encrypts` column and concluding every
company is unconfigured — does not apply. The Exigo credentials are plaintext
jsonb, which is its own problem but not this one.

**Solid Queue, Cache and Cable are not migrated.** The Next app runs webhook
handlers inline and has no worker. One behaviour change follows from dropping
Solid Cache: the preferred-status lookup cache is now per CONTAINER rather than
shared through a database. That is the safe direction — a cold container spends
one extra Fluid or Exigo lookup rather than reading a stale answer — but the hit
rate is lower than Rails', so expect slightly more Fluid traffic per cart burst.
`PREFERRED_LOOKUP_TTL_SECONDS` still tunes it.

---

## 8. What this PR does NOT port

Stated plainly so nobody reads the absence as an oversight. None of these is on
the callback path, and none blocks the cutover of any callback.

| Not ported | Why, and what to do about it |
|---|---|
| `PreferredCustomerSyncService` + `PreferredCustomerSyncJob` (the nightly Exigo reconciliation, ~385 lines) | It is a background job on `recurring.yml`'s `0 0 * * *`, not a request path. It keeps running on Rails throughout the cutover and must keep running until it is ported. Follow-up PR: Cloud Scheduler against an `ADMIN_API_TOKEN`-guarded route, or a Cloud Run Job. `ExigoClient` — the part the callbacks need — IS ported. |
| The dropzone UI (`/dashboard`, `/admin/{home,transactions,cart_pricing_events,integration_setting}`, `/customers`, `/price_types`) | Merchant-facing pages served from the Rails host. They are unaffected by a callback cutover: Fluid's dropzone config points at Rails and keeps doing so. They must NOT be ported as-is — every one of them is authenticated by a `dri` in the iframe URL and nothing else, and `/admin/integration_setting/edit` renders the Exigo DB password into a `value=` attribute. Porting them means fixing that first. |
| `PATCH /admin_api/company` | Ops endpoint, `ADMIN_API_TOKEN` bearer with `secure_compare`. Correct as it stands; port it with the dropzone work. |
| `ExigoClient#updateCustomerType` as a LIVE path | Ported, but dead — both Rails call sites are commented out and log `[EXIGO UPDATE DISABLED]`. Enabling it is a product decision, not a side effect of a migration. |
| `DropletReinstalledJob` registration | `droplet.reinstalled` is never registered by either app. The handler exists on both sides; nothing dispatches to it. |
