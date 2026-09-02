# Migrating `droplet-dynamic-pricing` from Rails 8 to Next.js

**This is a plan, not an implementation.** There is no application code in this PR — only this file.

This droplet rewrites the price of every line in a live cart. It is the only droplet in the
fleet whose failure mode is "the shopper is charged the wrong amount", and it does that work
across nine Fluid callbacks, six webhooks, an Exigo SQL Server connection and a nightly
reconciliation job. 3,767 lines of custom Ruby sit on top of the shared template, and roughly
900 of them are one file — `app/services/callbacks/base_service.rb` — whose comments read like
an incident log, because they are one. Porting that by feel is how a cart gets charged the
Canadian price in Philippine pesos, which is a thing that already happened once
(`base_service.rb:505-514`).

So: a plan first, then phases small enough that each one can be reverted by changing a URL.

## Measurement provenance

Everything below was measured at:

| Repo | Commit | Used for |
|---|---|---|
| `fluid-commerce/droplet-dynamic-pricing` | `5f3b5f9` (`origin/main`, "Merge PR #81 … settings do not mention yoli-promos") | the subject |
| `fluid-commerce/droplet-template` | `def6b9d` (`origin/main`, 2025-10-09) | the baseline for "identical to template" |
| `fluid-commerce/droplet-template` | PR **#200**, branch `claude/next-migration` @ `b11972f` | the reference shape for the Next app |
| `fluid-commerce/fluid` | `93f6499` (`origin/master`, 2026-08-25) | callback definitions, dispatch and failure semantics |
| `fluid-studios/packages/droplet-sdk` | `264cec5` (branch `claude/droplet-sdk-v1`), version `0.1.0` | `withFluidCallback` / `withFluidWebhook` |

**Do not read the local `fluid-main` checkout.** It sits on `fix/lifecycle-webhook-include-tokens`
@ `401fc85` (2026-03-09) with 18 definition files. Four are missing —
`cart_country_changed`, `cart_customer_attached`, `cart_customer_detached`,
`validate_cart_discount` — and **three of those four are definitions this droplet serves**.
Fetch `origin/master`.

---

## 0. The four things a reviewer should read first

1. **§3 — the shared brief's fail-open rule is wrong for this droplet, in the opposite
   direction from the tax droplets.** Fluid discards the HTTP status of eight of the nine
   callbacks this droplet serves. Failing closed on those is free and produces an alert;
   failing open buys nothing and hides auth failures. Exactly one route —
   `cart_email_on_create` — has its response applied to the cart, and that one must fail open.
2. **§7 F1 — every callback route is completely unauthenticated, and the tenant comes from
   the request body.** `Callbacks::BaseController` has no `before_action` at all
   (`app/controllers/callbacks/base_controller.rb:1-3`), and `find_company` reads
   `cart["company"]["id"]` (`app/services/callbacks/base_service.rb:186`). Fluid *does* sign
   every callback with HMAC-SHA256 (`fluid app/lib/callback/client.rb:392-403`); this droplet
   ignores the signature because it never stored the token needed to check it
   (`app/jobs/droplet_installed_job.rb:133-140`). This is the single largest thing the
   migration fixes, and it is why §5 Phase 3 exists before any route moves.
3. **§4 — `db/schema.rb` and `db/migrate/` agree exactly.** I reconciled all 11 tables against
   all 16 migrations. `prisma db pull` is therefore not required here, and translating
   `schema.rb` is safe — with the caveat in §4.2 about `companies.company_droplet_uuid`,
   which #200 got wrong once already and which this droplet **must not** declare unique.
4. **§5 Phase 6 — Exigo is a SQL Server dependency, not an HTTP one.** `tiny_tds` against Azure
   SQL, with hand-rolled `DECLARE @param` string interpolation rather than bind parameters
   (`app/clients/exigo_client.rb:124-154`). That is the one place where the Node ecosystem
   is not a drop-in.

---

## 1. Inventory

Measured by comparing the git blob sha of every `app/**/*.rb` and `lib/**/*.rb` path in this
repo at `5f3b5f9` against the same path in `droplet-template` at `def6b9d`. "Modified" means
the path exists in both and the blobs differ. Line counts are `wc -l` of this repo's copy.

### 1.1 Correcting the numbers in the brief

The brief's **32 identical / 7 modified / 57 custom** on `app/**/*.rb` is **exactly right for
the commit it was measured at, and that commit is stale.**

| | identical | modified | custom | total | custom LOC |
|---|---:|---:|---:|---:|---:|
| `db4262e` — the local `droplet-dynamic-pricing-main` checkout | 32 | 7 | **57** | 96 | **3,434** |
| `5f3b5f9` — `origin/main` | 32 | 7 | **58** | 97 | **3,767** |

The local checkout is **42 commits behind `origin/main`**. `db4262e` is "Add
subscription_volume_source for pc_cv/pc_qv volumes (#64)"; `origin/main` is at PR #81. The
brief's "~3,434 lines of custom Ruby" is likewise the `db4262e` figure — the current number is
**3,767**.

The one-file delta is not one file. Between the two commits:

- **added** `app/controllers/callbacks/cart_country_changed_controller.rb`,
  `app/services/callbacks/cart_country_changed_service.rb`, `app/errors/cross_country_price_error.rb`
- **removed** `app/controllers/callbacks/verify_email_success_controller.rb`,
  `app/services/callbacks/verify_email_success_service.rb` (commit `ad864d5`, "Remove the
  verify_email_success callback (CURRENT-3361)")

Net +1 file, +333 lines. **Anyone planning against `db4262e` will port a callback that no
longer exists and miss the one that does.**

`lib/**/*.rb` is 2 files, both byte-identical to the template (`lib/tasks/settings.rb` 218,
`lib/tasks/setup.rb` 40). Adding them: **34 identical / 7 modified / 58 custom, 99 files,
5,448 lines.**

### 1.2 (a) Byte-identical to the template — 34 files, 1,172 lines

Migrates once, upstream, in `droplet-template` PR #200. **Zero design work owed here.**

```
 17  app/clients/fluid/callback_definitions.rb
 65  app/clients/fluid/callback_registrations.rb
 45  app/clients/fluid/droplets.rb
 48  app/clients/fluid/webhooks.rb
  4  app/controllers/admin_controller.rb
 41  app/controllers/admin/callbacks_controller.rb
  4  app/controllers/admin/dashboard_controller.rb
 21  app/controllers/admin/droplets_controller.rb
 23  app/controllers/admin/settings_controller.rb
 61  app/controllers/admin/users_controller.rb
  4  app/controllers/home_controller.rb
 12  app/helpers/application_helper.rb
  7  app/jobs/application_job.rb
 13  app/jobs/droplet_reinstalled_job.rb
 72  app/jobs/webhook_event_job.rb
  4  app/mailers/application_mailer.rb
  3  app/models/application_record.rb
 26  app/models/callback.rb
 15  app/models/event.rb
 64  app/models/setting.rb
 20  app/models/user.rb
  2  app/models/webhook.rb
 11  app/permissions/ability.rb
  5  app/permissions/admin_permissions.rb
 22  app/permissions/permission_set.rb
 42  app/services/callback_sync_service.rb
 27  app/services/droplet_manager.rb
 71  app/services/event_handler.rb
 90  app/services/webhook_manager.rb
 39  app/use_cases/droplet_use_case/base.rb
 20  app/use_cases/droplet_use_case/create.rb
 16  app/use_cases/droplet_use_case/update.rb
218  lib/tasks/settings.rb
 40  lib/tasks/setup.rb
```

Every one has a finished TypeScript counterpart on #200 (`src/lib/services/droplet-manager.ts`,
`src/lib/callbacks/sync.ts`, `src/lib/events/event-handler.ts`, `src/lib/settings/defaults.ts`,
`src/lib/permissions/index.ts`, and so on).

### 1.3 (b) Template file, locally modified — 7 files, 509 lines

| File | Lines (template → local) | Diff vs template | What diverged |
|---|---|---|---|
| `app/models/integration_setting.rb` | 7 → **88** | +81 / −0 | 8 jsonb readers with in-code defaults + 7 Exigo credential keys. **Treat as custom** (§4.3). |
| `app/jobs/droplet_installed_job.rb` | 77 → **157** | +81 / −1 | registers 6 subscription webhooks; the `country_codes` omission (§2.1); discards `verification_token` (F1) |
| `app/jobs/droplet_uninstalled_job.rb` | 34 → **73** | +39 / −0 | deletes the subscription webhooks — but not `subscription.updated` (F4) |
| `app/clients/fluid_client.rb` | 62 → **68** | +29 / −23 | mixes in `Carts`, `Customers`, `Metafields`, `Subscriptions`, `Variants` |
| `app/controllers/webhooks_controller.rb` | 57 → **71** | +19 / −5 | flat/nested payload normalisation; `validate_droplet_authorization` on install/uninstall |
| `app/controllers/application_controller.rb` | 20 → **31** | +13 / −2 | `before_action :set_dri` — `@dri = params[:dri]`, the whole of the dropzone "auth" (F2) |
| `app/models/company.rb` | 17 → **21** | +4 / −0 | four `has_many`s and `has_one :integration_setting` |

### 1.4 (c) Genuinely custom — 58 files, 3,767 lines

Grouped by subsystem, because they migrate as units.

**The pricing engine — 1,425 lines. The dangerous part.**
```
878  app/services/callbacks/base_service.rb
 91  app/services/callbacks/subscription_removed_service.rb
 87  app/services/callbacks/customer_logged_in_service.rb
 77  app/services/callbacks/cart_country_changed_service.rb
 62  app/services/callbacks/cart_email_on_create_service.rb
 61  app/services/callbacks/cart_customer_detached_service.rb
 59  app/services/callbacks/cart_item_added_service.rb
 42  app/services/callbacks/cart_item_updated_service.rb
 37  app/services/callbacks/subscription_added_service.rb
 21  app/services/callbacks/cart_customer_attached_service.rb
  6  app/errors/cross_country_price_error.rb
  4  app/errors/callback_error.rb
```

**Callback HTTP surface — 257 lines.** Nine thin controllers plus a base that does no auth.
```
 33  app/controllers/callbacks/base_controller.rb
 29  app/controllers/callbacks/cart_item_updated_controller.rb
 27  app/controllers/callbacks/cart_item_added_controller.rb
 25  app/controllers/callbacks/cart_country_changed_controller.rb
 25  app/controllers/callbacks/subscription_added_controller.rb
 25  app/controllers/callbacks/subscription_removed_controller.rb
 24  app/controllers/callbacks/cart_customer_attached_controller.rb
 24  app/controllers/callbacks/customer_logged_in_controller.rb
 23  app/controllers/callbacks/cart_customer_detached_controller.rb
 22  app/controllers/callbacks/cart_email_on_create_controller.rb
```

**Subscription webhooks — 540 lines.**
```
217  app/services/webhooks/base_service.rb
 41  app/controllers/webhooks/base_controller.rb
 33  app/controllers/webhooks/subscription_started_controller.rb
 33  app/controllers/webhooks/subscription_cancelled_controller.rb
 33  app/controllers/webhooks/subscription_paused_controller.rb
 29  app/controllers/webhooks/subscription_reactivated_controller.rb
 29  app/controllers/webhooks/subscription_resumed_controller.rb
 28  app/services/webhooks/subscription_cancelled_service.rb
 28  app/services/webhooks/subscription_paused_service.rb
 23  app/services/webhooks/subscription_reactivated_service.rb
 23  app/services/webhooks/subscription_resumed_service.rb
 23  app/services/webhooks/subscription_started_service.rb
```

**Exigo + the nightly reconciliation — 634 lines.**
```
349  app/services/preferred_customer_sync_service.rb
249  app/clients/exigo_client.rb
 36  app/jobs/preferred_customer_sync_job.rb
```

**Fluid API surface this droplet added — 310 lines.**
```
122  app/clients/fluid/metafields.rb
 68  app/clients/fluid/customers.rb
 40  app/lib/connections/fluid.rb
 32  app/clients/fluid/subscriptions.rb
 31  app/clients/fluid/carts.rb
 17  app/clients/fluid/variants.rb
```

**Merchant-facing dropzone UI + ops API — 521 lines.** All but `admin_api` unauthenticated (F2).
```
 97  app/controllers/admin_api/companies_controller.rb
 83  app/controllers/price_types_controller.rb
 59  app/controllers/customers_controller.rb
 56  app/controllers/admin/integration_settings_controller.rb
 50  app/controllers/dynamic_pricing_dashboard_controller.rb
 36  app/controllers/admin/cart_pricing_events_controller.rb
 36  app/controllers/admin/transactions_controller.rb
 35  app/use_cases/price_type_use_cases/update.rb
 34  app/use_cases/price_type_use_cases/delete.rb
 29  app/controllers/admin/home_controller.rb
  6  app/controllers/public_admin_controller.rb
```

**Models — 80 lines.**
```
33  app/models/customer_type_transaction.rb
29  app/models/cart_pricing_event.rb
12  app/models/exigo_autoship_snapshot.rb
 6  app/models/price_type.rb
```

### 1.5 Views, frontend and tests — not counted above

Measured the same way against `def6b9d`.

- **ERB**: 14 custom (933 lines), 31 identical, 2 modified (`layouts/application.html.erb`,
  `shared/_header.html.erb`). The custom ones are the dropzone pages — the transactions and
  cart-events tables, the integration-settings form (186 lines) and show page (162), the
  price-types CRUD.
- **React/TS under `app/frontend`**: 7 custom (830 lines) — `dashboard.tsx` (172),
  `TransactionsTab.tsx` (158), `CartEventsTab.tsx` (142), plus a shadcn-style `ui/` set — and 7
  identical, 1 modified (`application.css`). **The stack is already React 19 + Tailwind 4 +
  Radix**, which is the same stack #200 targets. These port close to 1:1; only the Vite
  entrypoint mounting changes.
- **Tests**: 73 Minitest files, 9,409 lines, of which `test/services/callbacks/` is 10 files.
  Nothing here is reusable as-is, but the callback tests are the specification for §5 Phase 7's
  differential harness.

---

## 2. The Fluid integration surface

Cross-checked against all 22 definition files in `app/lib/callback_definitions/*.yml` on fluid
`origin/master` @ `93f6499`:

```
apply_subscription_order_discount   cart_country_changed        cart_customer_attached
cart_customer_detached              cart_customer_logged_in     cart_email_on_create
cart_item_added                     cart_item_removed           cart_item_updated
cart_subscription_added             cart_subscription_removed   deliver_email
evaluate_order_risk_kount           redirect_cart_payment       sync_missing_user
test_callback_system                update_cart_discount        update_cart_email
update_cart_shipping                update_cart_tax             validate_cart_discount
verify_email_success
```

### 2.1 Callbacks — nine, all real

Registered at install by `DropletInstalledJob#register_active_callbacks`
(`app/jobs/droplet_installed_job.rb:111-156`) from whichever `Callback` rows an operator has
marked active in the admin UI. `definition_name` is that row's `name`; the URL is that row's
`url`, typed in by hand. So the mapping below is route-to-definition by construction, and the
`Callback.name` values are constrained to real definitions because
`CallbackSyncService` only ever creates rows from `GET /api/callback/definitions`
(`app/services/callback_sync_service.rb:31`).

| `definition_name` | Rails route (`config/routes.rb`) | Service | Exists in Fluid? |
|---|---|---|---|
| `cart_item_added` | `POST /callbacks/cart_item_added` (`:18`) | `CartItemAddedService` | ✅ `cart_item_added.yml` |
| `cart_item_updated` | `POST /callbacks/cart_item_updated` (`:19`) | `CartItemUpdatedService` | ✅ `cart_item_updated.yml` |
| `cart_subscription_added` | `POST /callbacks/subscription_added` (`:16`) | `SubscriptionAddedService` | ✅ `cart_subscription_added.yml` |
| `cart_subscription_removed` | `POST /callbacks/subscription_removed` (`:17`) | `SubscriptionRemovedService` | ✅ `cart_subscription_removed.yml` |
| `cart_email_on_create` | `POST /callbacks/cart_email_on_create` (`:20`) | `CartEmailOnCreateService` | ✅ `cart_email_on_create.yml` |
| `cart_customer_logged_in` | `POST /callbacks/customer_logged_in` (`:21`) | `CustomerLoggedInService` | ✅ `cart_customer_logged_in.yml` |
| `cart_customer_attached` | `POST /callbacks/cart_customer_attached` (`:22`) | `CartCustomerAttachedService` | ✅ `cart_customer_attached.yml` |
| `cart_customer_detached` | `POST /callbacks/cart_customer_detached` (`:23`) | `CartCustomerDetachedService` | ✅ `cart_customer_detached.yml` |
| `cart_country_changed` | `POST /callbacks/cart_country_changed` (`:24`) | `CartCountryChangedService` | ✅ `cart_country_changed.yml` |

**Names to flag as nonexistent: none.** Two route names differ from their definition name
(`subscription_added` → `cart_subscription_added`, `customer_logged_in` →
`cart_customer_logged_in`) and the Next routes must be named for the definition, not the
directory — that is exactly the mistake zallevo #59 had to correct. `verify_email_success` was
served until `ad864d5` and is gone; do not resurrect it.

**`country_codes` is deliberately omitted at registration**
(`app/jobs/droplet_installed_job.rb:118-131`) and the comment there is **correct — I checked
it.** `Callback::Registration.scoped_to_country` (fluid `app/models/callback/registration.rb:90-95`)
does `next where(country_codes: []) if country_code.blank?`, and `Callback::Client.notify`
passes no country, so a registration that lists countries would never receive
`cart_country_changed`. **Carry this behaviour, and this comment, into the Next registration
code verbatim.**

### 2.2 Webhooks — 8 registered, 6 handled, 1 pointing at nothing

Two flows. The droplet-lifecycle pair is created by `WebhookManager` with the app-level API key
(`app/services/webhook_manager.rb:67-89`); the six subscription ones are created per company at
install with that company's token (`app/jobs/droplet_installed_job.rb:66-109`). All 6
subscription events are valid per fluid's `Webhook::TopicRegistry`
(`app/models/webhook/topic_registry.rb:51`).

| `resource.event` | Registered URL | Rails route | Handler |
|---|---|---|---|
| `droplet.installed` | `Setting.fluid_webhook.url` | `POST /webhook` (`routes.rb:8`) | `DropletInstalledJob` |
| `droplet.uninstalled` | `Setting.fluid_webhook.url` | `POST /webhook` | `DropletUninstalledJob` |
| `subscription.started` | `{host}/webhook/subscription_started` | `routes.rb:9` | `SubscriptionStartedService` |
| `subscription.paused` | `{host}/webhook/subscription_paused` | `routes.rb:10` | `SubscriptionPausedService` |
| `subscription.cancelled` | `{host}/webhook/subscription_cancelled` | `routes.rb:11` | `SubscriptionCancelledService` |
| `subscription.resumed` | `{host}/webhook/subscription_resumed` | `routes.rb:12` | `SubscriptionResumedService` |
| `subscription.reactivated` | `{host}/webhook/subscription_reactivated` | `routes.rb:13` | `SubscriptionReactivatedService` |
| `subscription.updated` | `{host}/webhook/cart_item_updated` | ❌ **no such route** | — (F4) |
| `droplet.reinstalled` | — never registered | — | `DropletReinstalledJob` — dead code |

### 2.3 Other HTTP surface

| Route | Purpose | Auth |
|---|---|---|
| `GET /` | marketplace landing | none (harmless) |
| `GET /dashboard?dri=` | dropzone: cart events + transactions | **`dri` only** (F2) |
| `GET/PATCH /admin/integration_setting?dri=` | dropzone: **reads and writes Exigo credentials** | **`dri` only, CSRF off** (F2) |
| `GET /admin/{home,transactions,cart_pricing_events}?dri=` | dropzone panels | **`dri` only** (F2) |
| `GET/PATCH /customers?dri=` | lists every customer and writes `customer_type` metafields | **`dri` only** (F2) |
| `/price_types` (full CRUD) | dropzone | **`dri` only** (F2) |
| `/admin/{dashboard,settings,users,callbacks,droplet}` | operator admin | Devise (`admin_controller.rb:3`) ✅ |
| `PATCH /admin_api/company` | ops: rename/deactivate an installation | `ADMIN_API_TOKEN` bearer, `secure_compare` ✅ |
| `GET /up` | health | none ✅ |

### 2.4 Fluid API endpoints this droplet calls

28 distinct paths across `app/clients/fluid/*.rb`. **None of them is
`/api/company/callbacks`** — the brief warns about that phantom endpoint and this droplet does
not call it. The callback endpoints used are `/api/callback/definitions` and
`/api/callback/registrations`, both real.

Notable: `PATCH /api/carts/{token}/update_cart_items_prices` (`fluid/carts.rb:23`) is the write
that changes what a shopper pays, and `PATCH /api/carts/{token}/items/{item_id}/update_volumes`
(`:27`) is the one that changes commission. `GET /api/company/v1/variants/{id}`
(`fluid/variants.rb:13`) is the `variant_country` lookup the cross-country guard depends on.

`Fluid::CallbackRegistrations` **already supports `page`/`per_page`**
(`app/clients/fluid/callback_registrations.rb:50-62`) — but nothing calls the index method;
only `.create` and `.delete` are used. The paging support is dead today and becomes live in
Phase 3.

---

## 3. Pricing risk — the brief's universal fail-open rule does not apply here

The brief says every callback response must be HTTP 200, auth failures included, because "a 401
is a broken cart". #200's example route says the same thing, about `cart_item_added` specifically.
**For this droplet, that is false for eight of nine routes, and I checked it in fluid's source
rather than assuming.**

### 3.1 What Fluid actually does with each response

All nine of this droplet's definitions are *notification* callbacks — their `response_schema` is
`{success: boolean, message?: string}` (plus `metadata`/`data` on two). None of them is
`update_cart_tax`, `update_cart_discount` or `update_cart_shipping`, so none of the response-is-
the-answer machinery applies.

`Callback::Client.request` does **not** raise on a non-2xx. The only exceptions it raises are
`DefinitionNotFoundError` / `InvalidCompanyError` / `InvalidPayloadError`, all pre-flight
(`fluid app/lib/callback/client.rb:92-102`). A real HTTP response — any status — is turned into a
`Data` object by `handle_sync_response` (`:436-450`) and handed back to the caller.

| Definition | Dispatched by | Sync? | Is the response read? | Effect of a non-2xx from us |
|---|---|---|---|---|
| `cart_item_added` | `CartItemCallbackSubscriber#deliver:53` | sync, on the shopper's thread | **no** — return value discarded at `:53` | none on the cart. Sentry `:http_error` + Slack `wecommerce_errors` |
| `cart_item_updated` | same | sync | no | same |
| `cart_subscription_added` | subscriber `:48` and `ManageSubscriptionAction#fire_subscription_callback:121` | sync | no | same |
| `cart_subscription_removed` | `ManageSubscriptionAction:121` | sync | no | same |
| `cart_customer_attached` | `CartCustomerCallbackSubscriber#deliver:48` | sync | no | same |
| `cart_customer_detached` | same | sync | no | same |
| `cart_customer_logged_in` | `Commerce::Cart#trigger_customer_logged_in_callback:1559` | sync | no | same |
| `cart_country_changed` | `UpdateCountryAction#notify_country_changed:74` — **`notify`, not `request`** | **async, thread pool** | no | none at all; not even on the request thread |
| **`cart_email_on_create`** | `CreateAction#request_email_callback:347` | sync | **YES** | **`enrich_cart_metadata` (`:363-371`) skips the response entirely unless `response.success?` — so a non-2xx silently drops the cart's `price_type` stamp** |

`Rails.event` is synchronous, and the subscribers are registered on it at
`fluid config/initializers/event_bus.rb:89,91`, so eight of the nine block the shopper's
request until we answer or the 20s ceiling expires (`Callback::Client::MAX_TIMEOUT_IN_MILLISECONDS`).
**Latency is the shared risk. Status is not.**

### 3.2 The rule, per route

**Eight routes fail closed. Pass no `on*` overrides at all.**

`cart_item_added`, `cart_item_updated`, `cart_subscription_added`, `cart_subscription_removed`,
`cart_customer_attached`, `cart_customer_detached`, `cart_customer_logged_in`,
`cart_country_changed`.

The SDK's defaults are already `401` / `400` / `500`
(`packages/droplet-sdk/src/next/callbacks.ts:83-88`, bound at `:107-116`), so the instruction is
to **write nothing** — not to pick a status. The reasoning:

- The cart outcome is identical either way. A refused request means the droplet did not reprice;
  so does a 200 neutral body. The shopper pays retail in both cases.
- A non-2xx is the only thing that produces an operator signal. Fluid's `classify_response`
  (`client.rb:206-224`) marks it `:http_error`, and `report_failure` (`:295-342`) raises a Sentry
  event and a `wecommerce_errors` Slack message, deduped 5 minutes per registration. A 200 neutral
  body produces silence — and silence is exactly the failure mode that let the callbacks run
  unauthenticated for a year.
- The oracle argument does not bite. These routes already leak nothing: they are *currently*
  open to anyone, and after Phase 3 an attacker who can forge a valid HMAC has the token anyway.

**One route fails open: `cart_email_on_create`.**

Its neutral body must be exactly:

```ts
const neutral = () => NextResponse.json({ success: true });
```

byte-identical across the auth-failure, invalid-body, handler-error and legitimate
"regular customer" paths, wired to all three `on*` hooks. Two constraints:

1. **The neutral body must not contain `metadata`.** `enrich_cart_metadata` merges
   `response.metadata` into `cart.metadata` with `update_column`. Returning
   `{success: true, metadata: {price_type: "preferred_customer"}}` on an auth failure would
   stamp preferred pricing onto a cart that has not earned it. `CartEmailOnCreateService#result_success`
   (`app/services/callbacks/cart_email_on_create_service.rb:56-61`) already returns that body on
   the *legitimate* preferred path — so the neutral body is the *other* one, the one at `:33`.
2. **The neutral body must contain `success`.** `classify_response` returns `:schema_invalid`
   for a 200 whose body fails `matches_response_schema?`, which alerts. `success` is the only
   required property.

Because the neutral body is identical to the genuine "regular customer, no special pricing
needed" answer, this route is not an oracle for token validity.

### 3.3 The two risks the status code does not cover

**Latency.** Eight callbacks sit on the shopper's request thread with a 20s ceiling. The Rails
services make up to five sequential Fluid calls per cart event (`get_customer_id_by_email` →
`get_customer_type_from_metafields` → `has_active_subscriptions?` → per-variant
`variant_country_row` → `update_items_prices`), plus an Exigo SQL round trip on the
`has_exigo_autoship_by_email?` path. **A Next port must not make this worse.** Phase 7's harness
should record call counts, not just outputs.

**Response body keys must be valid Ruby identifiers.** `build_response_data`
(`client.rb:162-188`) does `Data.define(*payload.keys)`. A key like `"error-code"` raises
`NameError` inside `request.on_complete`, which escapes `hydra.run` and is *not* caught by the
subscribers' `rescue ::Callback::Client::Error`. Keep bodies to `success` / `message` /
`metadata`.

---

## 4. Data — Rails schema to Prisma

### 4.1 `db/schema.rb` and `db/migrate/` agree. Translation is safe here.

I reconciled every table, column and index in `db/schema.rb` (version `2026_01_26_194025`,
11 tables) against all 16 files in `db/migrate/`. The schema version equals the timestamp of the
newest migration (`20260126194025_create_cart_pricing_events.rb`), every `create_table` and
`add_column` is accounted for, and every index in `schema.rb` traces to an `add_index` or a
`t.references`. There are no orphan tables from a shared Postgres instance and no drift.

**So this droplet does not need `prisma db pull`.** Translate `schema.rb`. (The sovos droplet
did need it; this one does not. Say so in the implementing PR, with this reconciliation as the
evidence.)

The three sidecar schemas — `db/queue_schema.rb`, `db/cache_schema.rb`, `db/cable_schema.rb` —
belong to Solid Queue / Cache / Cable in **separate databases** (`config/database.yml:22-38`:
`QUEUE_DATABASE_URL`, `CACHE_DATABASE_URL`, `CABLE_DATABASE_URL`). They are not mapped (§6).

### 4.2 Mapping rules

`@@map` every model to its Rails table, `@map` every non-camelCase column,
`BigInt @id @default(autoincrement())` for every primary key (Rails 8 emits `bigserial`),
`jsonb → Json`, `t.string array: true → String[] @default([])`,
`decimal(10,2) → Decimal @db.Decimal(10, 2)`. Mirror every index and its uniqueness exactly.
**No column is renamed, dropped or retyped.**

**The uniqueness trap, checked column by column.** #200 declared `@unique` on a column whose
Rails index is a plain index and had to fix it in `b11972f`; deploys run `prisma db push`, so a
spurious `@unique` tries to add a constraint to a live table. Here is the audit:

| Table.column | `schema.rb` | Migration | Prisma |
|---|---|---|---|
| `companies.authentication_token` | `unique: true` (`:60`) | `create_companies.rb` `add_index … unique: true` | `@unique` ✅ |
| `companies.fluid_shop` | plain (`:63`) | plain | `@@index` — **not** `@unique` |
| `companies.fluid_company_id` | plain (`:62`) | plain | `@@index` — **not** `@unique`. `AdminApi::CompaniesController:54-69` explicitly handles duplicates. |
| `companies.company_droplet_uuid` | plain (`:61`) | plain | `@@index` — **not** `@unique`. It holds the *droplet's* uuid, identical on every row (F3). |
| `companies.active` | plain (`:59`) | plain | `@@index` |
| `companies.droplet_installation_uuid` | **no index at all** | none | **no index.** Do not add one — `companies` holds a handful of rows and the sequential scan `resolvePrincipal` does per callback is not worth a `db push` against a live table. |
| `settings.name` | `unique: true` (`:132`) | `index: { unique: true }` | `@unique` ✅ |
| `users.email` | `unique: true` (`:144`) | `add_index … unique: true` | `@unique` ✅ |
| `users.reset_password_token` | `unique: true` (`:145`) | `add_index … unique: true` | `@unique` ✅ |
| `price_types.[company_id, name]` | `unique: true` (`:121`) | `add_index … unique: true` | `@@unique([companyId, name])` ✅ |
| `integration_settings.company_id` | plain (`:113`) | `t.references` | `@@index` — **not** `@unique`, even though Rails declares `has_one`. This is the exact #200 bug. |
| `callbacks.name` | **no index** | none | **no index**, despite `validates :name, uniqueness: true` in `app/models/callback.rb:4`. Model-level only; do not promote it. |
| `events.identifier` | plain (`:92`) | plain | `@@index`. No idempotency guarantee. |
| everything else | plain | plain | `@@index` |

### 4.3 Table-by-table

| Rails table | Prisma model | Notes |
|---|---|---|
| `companies` | `Company` | `installed_callback_ids` jsonb `[]`; `settings` jsonb `{}`; `fluid_company_id` **BigInt**; `active` default false |
| `callbacks` | `Callback` | global catalog, no company FK, all columns nullable, `active` nullable with **no default** |
| `events` | `Event` | `status` is a plain `Int?` (AR integer enum `pending:0, processed:1, failed:2`; the default lives in the model, **not** the column). **No call site writes this table** — map it, invent no behaviour |
| `webhooks` | `Webhook` | `app/models/webhook.rb` is an empty class and nothing references it. Map it to account for the table; port no behaviour |
| `settings` | `Setting` | `schema` jsonb NOT NULL; `values` jsonb `{}`; `name` unique |
| `users` | `User` | `permission_sets` `String[] @default([])`; `encrypted_password` bcrypt |
| `integration_settings` | `IntegrationSetting` | see below |
| `price_types` | `PriceType` | `@@unique([companyId, name])` |
| `cart_pricing_events` | `CartPricingEvent` | `cart_id` is `Int?` not BigInt; `cart_total` `Decimal @db.Decimal(10,2)`; `event_type` is a **string-backed** AR enum → plain `String?`, do not create a Postgres enum |
| `customer_type_transactions` | `CustomerTypeTransaction` | `source` string-backed enum → plain `String?` |
| `exigo_autoship_snapshots` | `ExigoAutoshipSnapshot` | **`external_ids` is `t.json`, not `t.jsonb`.** Prisma's `Json` maps to `jsonb` by default — this one needs `@db.Json` or `db push` will try to alter the column type on a live table |
| — | `FluidCallbackRegistration` | the one **new** table, owned by the SDK. Copy `vendor/droplet-sdk/schema/callback-registrations.prisma` verbatim. Additive; Rails neither reads nor writes it, so both apps can run against the database at once |

### 4.4 What does not map cleanly

**`integration_settings.settings` and `.credentials` are schemaless with in-code defaults.**
There are no `store_accessor`s — `app/models/integration_setting.rb` hand-writes eight readers,
each with a default that exists nowhere in the database:

| Reader | jsonb key | Default | Line |
|---|---|---|---|
| `yield_to_enrollment_wholesale?` | `yield_to_enrollment_wholesale` | `false` | `:28-30` |
| `adjust_volumes_for_subscription?` | `adjust_volumes_for_subscription` | `false` | `:37-39` |
| `subscription_volume_source` | `subscription_volume_source` | `"price_ratio"` | `:52-54` |
| `preferred_customer_type_id` | `preferred_customer_type_id` | `"2"` (String) | `:56-58` |
| `retail_customer_type_id` | `retail_customer_type_id` | `"1"` (String) | `:60-62` |
| `api_delay_seconds` | `api_delay_seconds` | `0.5` (Float) | `:64-66` |
| `snapshots_to_keep` | `snapshots_to_keep` | `5` | `:68-70` |
| `daily_warmup_limit` | `daily_warmup_limit` | `10_000` | `:72-74` |

Port these as a **Zod schema with `.default()` on every field**, parsed on read. Two traps:
`yield_to_enrollment_wholesale?` and `adjust_volumes_for_subscription?` run the value through
`ActiveModel::Type::Boolean`, so the string `"1"`, `"true"` and `"t"` are all true and `"0"`,
`"false"`, `"f"` and `""` are all false — a bare `Boolean(value)` in TypeScript gets `"false"`
wrong. And `PreferredCustomerSyncService` (`:297-303`) falls back to **integers** `2`/`1` for the
same two type-ids the model returns as **strings** `"2"`/`"1"`; the comparison at `:253`
normalises with `.to_i`, so the behaviour is right but the values recorded in
`CustomerTypeTransaction.metadata` differ by path. Pick one and note the change.

**`Setting`'s dynamic accessors.** `Setting.fluid_webhook.auth_token` is two levels of
`method_missing` (`app/models/setting.rb:11-32`) — class-level name lookup, instance-level jsonb
key lookup — plus auto-seeding when the table is empty (`:12`). #200 already ports this as
`src/lib/settings/index.ts` with Ajv replacing `json_schemer`; reuse it. The seven seeded
settings in `lib/tasks/settings.rb` are byte-identical to the template's.

**Exigo credentials are plaintext jsonb.** `integration_settings.credentials` holds
`exigo_db_host`, `exigo_db_username`, `exigo_db_password`, `exigo_db_name`, `api_base_url`,
`api_username`, `api_password` in the clear (`app/models/integration_setting.rb:11-21`), and an
unauthenticated endpoint renders and rewrites them (F2). The migration does not change this —
encrypting it is a separate decision on a separate PR — but the Next port must not *widen* it,
and F2 must be fixed before Phase 4 exposes the same page.

**Devise → Auth.js works on the existing rows.** `encrypted_password` is bcrypt; `config.pepper`
is commented out in `config/initializers/devise.rb`, so the digest is plain bcrypt at
`config.stretches = 12`. `bcryptjs@2.x` reads and writes the `$2a$` prefix that bcrypt-ruby
produces, so **no user needs to reset a password and both apps can authenticate the same rows
while running side by side.** #200 confirms this with a round-trip test against recorded
bcrypt-ruby output (`src/lib/auth/password.test.ts`).

---

## 5. Sequenced phases

Sizes are rough: **S** ≈ a day, **M** ≈ 2–4 days, **L** ≈ 1–2 weeks, **XL** ≈ 2+ weeks. No dates.

Every phase after 0 is independently reviewable, deployable and revertible. **No phase before 11
touches `cloudbuild-production.yml`, `.github/workflows/deploy-production.yml` or
`docker/Dockerfile`** — the Rails production pipeline is frozen for the duration, and the Next
app deploys as a *separate* Cloud Run service in the same project (`fluid-417204`,
`europe-west1`). That separation is what makes the cutovers reversible: **a Fluid callback
registration carries a URL per definition, so a phase is cut over by pointing one registration's
URL at the Next service and reverted by pointing it back.** No code deploy, no database change.

### Phase 0 — Rails-side fixes worth shipping regardless. **S.** *Not a migration phase.*

Three items from §7, all on the Rails app, all shippable this week whether or not the migration
happens:

- **F2**: put `authenticate_user!` or a signed-`dri` check in front of `PublicAdminController`
  and the two `dri`-only controllers, or at minimum in front of
  `Admin::IntegrationSettingsController#update` and `CustomersController#update`, which are
  unauthenticated *writes*.
- **F5**: drop `Setting.fluid_webhook.auth_token` from the `include?` in
  `webhooks/base_controller.rb:23` and `webhooks_controller.rb:55` for non-lifecycle events, and
  use `ActiveSupport::SecurityUtils.secure_compare` instead of `include?`.
- **F4**: point the `subscription.updated` registration at a route that exists, or stop
  registering it — and add `"updated"` to the uninstall filter at
  `droplet_uninstalled_job.rb:46` either way.

**Verify before proceeding:** an unauthenticated `PATCH /admin/integration_setting?dri=<uuid>`
returns 401/302; a webhook signed with the shared token but naming another company's
`company_id` returns 401; `subscription.updated` no longer produces 404s in Cloud Logging.

### Phase 1 — Migrate `droplet-template` to Next.js. **XL, and not in this repo.**

Merge `fluid-commerce/droplet-template#200`. It supplies the entire §1.2 layer — Prisma over the
shared tables, Auth.js against Devise digests, the admin UI, `withFluidWebhook`, the Fluid
client, `EventHandler`, settings, the callback token store and `backfill:callbacks`. Everything
below inherits it.

**Verify:** #200 is merged to `droplet-template@main` and its CI is green.

### Phase 2 — Scaffold the Next app alongside Rails. **M.**

Copy #200's shape: root `package.json` (pnpm 10.17.1), `src/` as the Next project directory with
`next build src` (Next's `findDir(root,"app")` prefers Rails' `app/` and cannot be overridden),
root `tsconfig.json` plus `src/tsconfig.json`, `vitest.config.ts`, `eslint.config.mjs`,
`Dockerfile.next`, `.github/workflows/ci-next.yml`, `/api/health` that touches no database.

Write `prisma/schema.prisma` per §4 — **all 11 tables plus `FluidCallbackRegistration`**, seven
more models than #200 has.

**The SDK is vendored, not installed.** The brief says to depend on
`@fluid-studios/droplet-sdk` from GitHub Packages via an `.npmrc`. **That is not possible today
and #200 does not do it:** GitHub Packages requires the npm scope to match the repository owner,
the owner is `fluid-commerce`, there is no `fluid-studios` GitHub org, and publishing returns
`403 Permission not_found: owner not found`. Copy #200's approach — `vendor/droplet-sdk` with
`"@fluid-studios/droplet-sdk": "link:./vendor/droplet-sdk"`, `transpilePackages` in
`next.config.ts`, the vendor dir copied into the Docker build *before* `pnpm install`. Note the
one-line swap for when the package is published.

No routes take traffic. Nothing deploys yet.

**Verify:** `pnpm install && pnpm db:generate && pnpm lint && pnpm typecheck && pnpm test &&
pnpm build` is green in CI. `prisma migrate diff --from-url $PROD_SNAPSHOT_URL
--to-schema-datamodel prisma/schema.prisma` reports **only** `CREATE TABLE
fluid_callback_registrations` and nothing else — no `ALTER`, no index changes. `bin/rails
db:migrate:status` on the Rails app is unchanged.

### Phase 3 — Callback token infrastructure and backfill. **S. Behaviourally inert.**

Create `fluid_callback_registrations`. Port `registerCallbacksForCompany` from #200 —
capture `verification_token` from the create response (Fluid returns it only there:
`Callback::RegistrationBlueprint` `:api_create` view includes it, `:api_update` does not, and
`UpdateAction`'s params schema refuses it), store `tokenDigest(...)` and **never the plaintext**,
and delete the registration you just created if the token is absent or the digest write fails.

Add `scripts/backfill-callback-tokens.ts` and a `backfill:callbacks` script that **stages the
full replacement set, checks every enabled definition is present, then swaps in one
transaction** — never delete an installation's digests before you hold their replacements.
`listCallbacks` must forward `{page, per_page}`; the Ruby client already builds that query string
(`app/clients/fluid/callback_registrations.rb:50-62`) and no caller uses it. The endpoint is
company-scoped, so filter by **exact** URL set membership, never `startsWith`.

**Rollout order inside this phase is not negotiable:** deploy the table and the registration
code; run `pnpm backfill:callbacks` **by hand** against production until it exits zero; only then
let Phase 8 point a registration at a wrapped route. Reversed, every genuine callback is rejected.

**Verify:** `fluid_callback_registrations` has one row per (installation × active definition),
`SELECT count(*) FROM fluid_callback_registrations WHERE token_digest IS NULL OR token_digest = ''`
returns 0, and no plaintext `cvt_` appears anywhere in the table. Rails is untouched and still
serving.

### Phase 4 — Admin, dropzone and ops surfaces. **L.**

Port the Devise-guarded `/admin/*` pages (#200 supplies most), then this droplet's own:
dashboard stats, cart-pricing-events table, transactions table, price-types CRUD, the customers
list and metafield write, the integration-settings form, and `PATCH /admin_api/company`.

The React under `app/frontend/components` is already React 19 + Tailwind 4 + Radix and moves
close to 1:1; only the Vite entrypoints become App Router pages.

**Fix F2 in the same phase.** The Next versions of the dropzone pages must not ship with `dri`
as the only credential. Decide between (a) Fluid-signed dropzone tokens, (b) a session
established by a signed handshake, (c) Devise/Auth.js login for the write paths and `dri` for
read-only — in that order of preference. **Do not port `PublicAdminController`.**

**Verify:** the Next dropzone pages render byte-comparable data to the Rails ones for a chosen
installation; an unauthenticated write to the Next `/admin/integration-setting` is refused; the
Rails pages still work. Fluid's dropzone config still points at Rails.

### Phase 5 — Webhook ingestion. **M.**

`POST /api/webhooks` with `withFluidWebhook`, plus the five subscription routes. **Pass no `on*`
overrides** — webhooks are not the checkout path and a refusal is a retry.

Fluid signs webhooks with HMAC-SHA256 over `{timestamp}.{body}` keyed on the webhook's stored
`auth_token` (`fluid app/models/webhook.rb:181-188`), alongside the plaintext `AUTH_TOKEN`
header the Rails app compares today. So `withFluidWebhook`'s signature path works with no Fluid
change: `resolve` returns `company.webhookVerificationToken`, and `bootstrapSecret` is
`FLUID_WEBHOOK_AUTH_TOKEN` restricted to `["droplet.installed", "droplet.uninstalled"]`. This
replaces `validate_droplet_authorization` (`application_controller.rb:7-14`), which authenticates
an install by comparing a caller-supplied `droplet_uuid` against `ENV["DROPLET_UUID"]` (F3).

Port `DropletInstalledJob` (including the six subscription registrations and the `country_codes`
omission), `DropletUninstalledJob` and `DropletReinstalledJob` — and **register**
`droplet.reinstalled` this time.

**Cut over by editing data, not code:** point `Setting.fluid_webhook.values.url` at the Next
service and press Update Droplet on the admin dashboard, which pushes it to Fluid via
`PUT /api/company/webhooks/:id`. Re-register the five subscription webhook URLs. Revert is the
same two edits.

**Verify:** a real install on a test company creates the `companies` row, all nine
`fluid_callback_registrations` rows with digests, and all six subscription webhooks — with the
Rails app receiving nothing. A webhook signed with the shared token for `subscription.started`
is refused. An uninstall removes all six webhooks and all nine registrations.

### Phase 6 — Exigo and the nightly reconciliation. **M.**

Port `ExigoClient` (249 lines) and `PreferredCustomerSyncService` (349). `tiny_tds` has no Node
equivalent that behaves identically; use `mssql`/`tedious` with `encrypt: true` for Azure. **Use
real bind parameters** — the Ruby interpolates `DECLARE @paramN <type> = <quoted literal>` and
relies on `gsub("'", "''")` (`exigo_client.rb:124-154, 231-248`).

Reproduce exactly: the warmup-vs-delta branch and its `daily_warmup_limit` cap
(`preferred_customer_sync_service.rb:53-81`), the `api_delay_seconds` sleep between customers,
the snapshot pruning to `snapshots_to_keep`, and the metafield-update-with-create-on-404 fallback.

**Note that the Exigo write path is commented out in Rails** (`webhooks/base_service.rb:117-119`
and `preferred_customer_sync_service.rb:255-257` both log `[EXIGO UPDATE DISABLED]`).
`ExigoClient#update_customer_type` is dead in production. **Port it dead.** Turning it on is a
separate decision, not a side effect of a migration.

`recurring.yml`'s `"0 0 * * *"` becomes Cloud Scheduler hitting an `ADMIN_API_TOKEN`-guarded
route, or a Cloud Run Job. Say which and why in the PR.

**Verify:** a dry run against a production Exigo snapshot produces the same promote/demote sets
as the Rails job for the same day, and the same `ExigoAutoshipSnapshot.external_ids`. The Rails
recurring job is still the one scheduled.

### Phase 7 — The pricing engine as a pure library, with a differential harness. **L. No routes.**

Port `base_service.rb` and the nine services into `src/lib/pricing/`, exporting pure functions
that return a *description* of what they would do — the sequence of Fluid calls with their
arguments — rather than performing them. Nothing is wired to a route.

The things that must survive verbatim, each with its incident number in the Ruby:

- the settled-cart denylist and `refuse_settled_write` (`:12, :119-127`, CURRENT-3361)
- `preferred_lookup_failed?` — "unknown" must never be read as "not preferred" (`:129-139`)
- `country_safe_price` and `refuse_cross_country_price` (`:505-621`, STU2-3108 — the PH cart
  charged 113.85 instead of 2,499)
- the zero-price guard in `update_cart_items_prices` (`:422-430`)
- `bundle_priced?` / `bundle_group_base_price` — never read `variant_country` for a bundle (`:469-496`)
- `locked_cart_items` — only lines carrying `metadata.price_locked` (`:477-485`)
- `update_cart_items_volumes` and both `subscription_volume_source` modes (`:240-330`, STU2-2526/2531)
- the `yield_to_enrollment_wholesale?` / `price_type_wholesale?` yield to the BP droplet (STU2-2377/2964)
- Ruby coercion semantics: `to_f`, `to_i`, `blank?`, `present?`, and `nonzero_price` treating
  `"0.0"` as absent but `bundle_group_base_price` deliberately not

**Verification is the whole point of this phase:** replay a corpus of captured production
callback payloads through both the Rails services and the TypeScript library and assert the
emitted call sequences are **identical, including order and argument values**. Capture the corpus
from Cloud Logging; it must include at least one settled cart, one bundle, one cross-country
cart, one enrollment cart, one cart with `price_locked` lines and one where the preferred lookup
fails. Record Fluid API call *counts* too — §3.3.

### Phase 8 — Cut over `cart_country_changed`. **S. The canary.**

The safest of the nine: dispatched with `notify` (async thread pool), response never read, fires
only on a real country transition, and touches only lines this droplet locked.

Register a `POST /api/callbacks/cart-country-changed` route with
`definitions: ["cart_country_changed"]` and **no `on*` overrides**. Cut over for **one test
company first** by editing that company's registration URL.

**Verify:** the `[fluid-callback:cart_country_changed] rejected` log line never appears; a
country change on a cart with locked lines produces the same `update_cart_items_prices` payload
the Rails app produced for the same cart shape; `CartPricingEvent` rows with
`event_type: "country_changed"` continue to appear. Hold for a week before Phase 9.

### Phase 9 — Cut over `cart_email_on_create` and the three customer-lifecycle callbacks. **M.**

`cart_email_on_create` (fail **open**, §3.2), `cart_customer_logged_in`,
`cart_customer_attached`, `cart_customer_detached` (fail **closed**).

`cart_customer_attached` is the high-traffic one — its `order_completion` trigger is roughly 39%
of its volume per the comment at `customer_logged_in_service.rb:17-21` — and it inherits
`CustomerLoggedInService` with only `customer_email` overridden. `cart_customer_detached` only
rolls back pricing it applied (`cart_customer_detached_service.rb:36-41`); that guard is half of
the CURRENT-3361 oscillation fix and must not be simplified away.

Cut over per definition, per company, in that order.

**Verify:** for a test company, a cart created with a preferred customer's email still receives
`metadata.price_type = "preferred_customer"` (this is the response-consuming path — check
`carts.metadata` in Fluid, not the droplet's logs); a logout on a stamped cart restores retail
prices and clears the stamp; a login on an unstamped cart applies subscription prices. Diff
`cart_pricing_events` volumes against the prior week.

### Phase 10 — Cut over the four item and subscription callbacks. **L. The dangerous one.**

`cart_item_added`, `cart_item_updated`, `cart_subscription_added`, `cart_subscription_removed`.
These are the ones that reprice every line on every add-to-cart. All fail closed.

Cut over **one definition at a time, one company at a time**, starting with the lowest-volume
installation. Between each, hold for a full business day.

**Verify:** for each cut-over definition, the distribution of `cart_pricing_events.cart_total`
and `preferred_pricing_applied` matches the prior week for the same company; zero
`[fluid-callback:…] rejected` lines; zero `Refusing to set zero price` warnings that Rails did
not also produce; p95 callback latency (New Relic `CallbackRequest` custom event, `duration_ms`)
no worse than the Rails baseline. **Roll back by re-pointing the registration URL** — the Rails
app is still running and still correct.

### Phase 11 — Decommission Rails. **S. A follow-up PR.**

Only after every registration and webhook points at the Next service and the Rails Cloud Run
service has been scaled to zero for a full week with no incident. Move `next.config.ts`,
`src/tsconfig.json` and `next-env.d.ts` up one level, drop the `src` argument from the Next
commands, rename `Dockerfile.next` to `Dockerfile`, repoint `cloudbuild-production.yml`, delete
`app/`, `config/`, `db/`, `test/`, `Gemfile`, `Procfile`, `bin/`, `.kamal/`.

---

## 6. What I would not migrate

| Thing | Why |
|---|---|
| **Solid Queue / Cache / Cable** and their three separate databases (`config/database.yml:22-38`) | The only queued work is `WebhookEventJob` and its `retry_on … attempts: 5`. Fluid already retries webhooks; run handlers inline like #200 does, and let a non-2xx be the retry signal. The nightly job becomes Cloud Scheduler. Three databases disappear. |
| **The `webhooks` table and `Webhook` model** | `app/models/webhook.rb` is `class Webhook < ApplicationRecord; end` and nothing in `app/` references it. Map the table so `db push` leaves it alone; port no behaviour. |
| **The `events` table's behaviour** | Mapped, indexed, FK'd — and never written. `grep` finds no `Event.create` anywhere. Do not invent an audit trail that did not exist. |
| **`PublicAdminController`** | Its entire content is `layout` + `skip_before_action :verify_authenticity_token`. It is the mechanism by which four `/admin/*` routes are unauthenticated (F2). Replace, do not port. |
| **`validate_droplet_authorization`** (`application_controller.rb:7-14`) | Authenticating an install by comparing a caller-supplied `droplet_uuid` against `ENV["DROPLET_UUID"]` is not authentication (F3). `withFluidWebhook`'s bootstrap HMAC replaces it; keep the uuid comparison inside the handler as a routing guard. |
| **`ExigoClient#update_customer_type` as a live path** | Commented out in both call sites. Port it dead; enabling it is a product decision. |
| **The `docs/` Jekyll site** and `.github/workflows/docs.yml` | Unrelated to the app; leave in place. |
| **`.kamal/`, `config/deploy.yml`, `app.json`, `makefile`, `Procfile`** | Dead deploy paths. Nothing in `.github/workflows/` references any of them, and `docker/Dockerfile:96` runs `./bin/thrust ./bin/rails server` directly rather than a Procfile; production is Cloud Build → Cloud Run. (`Procfile.dev` is local-dev only and dies with Rails.) |
| **Devise `:registerable`, `:recoverable`, `:rememberable`** and their 12 mailer/confirmation/unlock ERB views | #200 ports only `:database_authenticatable` + `:validatable`. The columns stay so password reset can be added later without a migration. |
| **CanCanCan as it is currently wired** | `current_ability` is defined (`application_controller.rb:22-24`) but **no controller ever calls `authorize!`, `can?` or `load_and_authorize_resource`** — grep returns zero hits. It is decoration. #200's `can()` module plus real route guards replaces it with something that actually runs. |
| **`verify_email_success`** | Removed on `main` in `ad864d5`. Only a plan measured at the stale `db4262e` would port it. |
| **The two commits on `droplet-dynamic-pricing.claude-fix-zero-price-on-subscription-removed`** | See §8. |

---

## 7. Findings — evidence, not speculation. None are fixed here.

Each needs its own fix and its own PR.

### The four known fleet patterns, checked

| Pattern | Present? | Where |
|---|---|---|
| `[ Setting.fluid_webhook.auth_token, company.webhook_verification_token ].include?(auth_header)` — one droplet-wide token authenticates a webhook about any company | **Yes**, verbatim, in two places | `webhooks/base_controller.rb:23`, `webhooks_controller.rb:55` → **F5** |
| `find_company` keying on `company_droplet_uuid` — the *droplet's* uuid, identical on every row | **Yes**, inherited byte-identical from the template | `webhook_event_job.rb:42-47` → **F10**. Partially masked because Fluid never sends that key; see F10. |
| `droplet.installed` skipping authentication entirely | **No — but it is not authenticated either.** It has `validate_droplet_authorization`, which compares a caller-supplied `droplet_uuid` against `ENV["DROPLET_UUID"]` | `application_controller.rb:7-14`, wired at `webhooks_controller.rb:3` → **F3** |
| Callback routes with no authentication at all | **Yes — all nine** | `callbacks/base_controller.rb:1-3` → **F1** |

The one this droplet has that the others do not: an entire unauthenticated `/admin/*` subtree
whose only credential is a URL-borne `dri` (**F2**).

### F1 — Callback routes have no authentication, and the tenant comes from the request body. *(critical)*

`app/controllers/callbacks/base_controller.rb:1-3` is the entire guard:

```ruby
class Callbacks::BaseController < ApplicationController
  skip_before_action :verify_authenticity_token
```

No `before_action` for auth. All nine callback routes inherit it. The company is then resolved
from the body — `app/services/callbacks/base_service.rb:183-186`:

```ruby
company_data = cart&.dig("company")
raise CallbackError, "Company data is blank" if company_data.blank?

@company = Company.find_by(fluid_company_id: company_data["id"])
```

and that company's stored Fluid `authentication_token` is what the droplet then uses
(`:165-170`). So an unauthenticated POST naming any installed company's `fluid_company_id`
makes the droplet act **on that company's behalf** with that company's credentials: rewrite
every line price on a cart it names, write cart metadata, and write customer metafields.

Fluid *does* provide the material to prevent this. `Callback::Client#generate_signed_headers`
(`fluid app/lib/callback/client.rb:392-403`) sends `X-Fluid-Signature` (HMAC-SHA256 over
`{timestamp}.{body}`), `X-Fluid-Timestamp` and `X-Fluid-Callback-Token` on **every** callback.
The droplet reads none of them, because the key — the per-registration `verification_token` — was
discarded at install (`app/jobs/droplet_installed_job.rb:133-140` keeps only `uuid`), and there
is no column for it.

**Fix:** Phase 3 + `withFluidCallback`, with `resolvePrincipal` reading `registration.dri` and
nothing else.

**Not verified:** whether this has been exploited. I did not query production logs, and I make
no claim about it.

### F2 — Four `/admin/*` routes, the whole dropzone and a customer-write endpoint are unauthenticated. *(critical)*

`app/controllers/public_admin_controller.rb:3-6`:

```ruby
class PublicAdminController < ApplicationController
  layout "public_dashboard"
  skip_before_action :verify_authenticity_token
end
```

`Admin::HomeController`, `Admin::TransactionsController`, `Admin::CartPricingEventsController`
and `Admin::IntegrationSettingsController` all inherit it. Their only gate is
`Company.find_by(droplet_installation_uuid: @dri)`, where `@dri` is `params[:dri]`
(`application_controller.rb:28-30`). `CustomersController`, `PriceTypesController` and
`DynamicPricingDashboardController` use the same `dri` gate with no Devise.

A `dri` is an unguessable but **non-secret** identifier that travels in a dropzone iframe URL —
so it reaches browser history, `Referer` headers and any analytics on the page. With one, an
attacker can:

| Route | Impact |
|---|---|
| `GET /admin/integration_setting/edit?dri=` (`integration_settings_controller.rb:8-10`) | **renders the company's Exigo DB password and API password in plaintext into the `value=` attribute** — `app/views/admin/integration_settings/_form.html.erb:69` and `:89` pass `credentials["exigo_db_password"]` / `credentials["api_password"]` to `password_field_tag`, so they are in the HTML source. Host, username, database name and API base URL likewise. |
| `PATCH /admin/integration_setting?dri=` (`:32-54`) | **overwrites** all seven credentials, and toggles `yield_to_enrollment_wholesale` / `adjust_volumes_for_subscription` / `subscription_volume_source` — i.e. changes how that company's carts are priced. CSRF is off. |
| `GET /customers?dri=` (`customers_controller.rb:9-14`) | lists every customer via the company's Fluid token |
| `PATCH /customers/:id?dri=` (`:17-28`) | writes `customer_type` metafields — flipping a customer between preferred and retail pricing |
| `/price_types` CRUD | creates/deletes price types on the company's Fluid account |

`AdminController` **does** have `before_action :authenticate_user!`
(`app/controllers/admin_controller.rb:3`), so the operator admin (`settings`, `users`,
`callbacks`, `droplet`) is fine. The problem is confined to the `PublicAdminController` tree and
the three `dri`-only controllers.

**Fix:** Phase 0, then Phase 4. The plaintext-in-`value=` rendering is worth fixing on its own
even if the auth question takes longer.

### F3 — Install/uninstall authenticate on a value the caller supplies. *(high)*

`app/controllers/application_controller.rb:7-14`:

```ruby
def validate_droplet_authorization
  droplet_uuid = params.dig(:company, :droplet_uuid) || params.dig(:payload, :company, :droplet_uuid)
  expected_uuid = ENV["DROPLET_UUID"]

  unless droplet_uuid.present? && droplet_uuid == expected_uuid
    render json: { error: "Invalid droplet UUID" }, status: :unauthorized
  end
end
```

Wired at `webhooks_controller.rb:3` for `droplet.installed` / `droplet.uninstalled`. A droplet
uuid is an identifier Fluid publishes, not a secret. A forged install hands this droplet a
`companies` row whose `authentication_token` and `webhook_verification_token` are whatever the
caller chose — and `DropletInstalledJob` matches on `fluid_shop`
(`droplet_installed_job.rb:19`), so it can also **overwrite an existing installation's stored
credentials**.

Note this is *better* than the fleet norm — several droplets skip authentication on
`droplet.installed` entirely. It is still not authentication.

**Fix:** Phase 5.

### F4 — The `subscription.updated` webhook points at a route that does not exist, and is never cleaned up. *(medium)*

`app/jobs/droplet_installed_job.rb:74`:

```ruby
{ event: "updated", url: subscription_webhook_url(base_url, "cart_item_updated") },
```

which builds `{base_url}/webhook/cart_item_updated`. `config/routes.rb:8-13` declares
`POST /webhook` and the five `POST /webhook/subscription_*` routes — nothing matches. Every
`subscription.updated` fires into a 404. (`cart_item_updated` *is* a real endpoint, but it is a
**callback** at `POST /callbacks/cart_item_updated`, not a webhook.)

Separately, `droplet_uninstalled_job.rb:46` filters cleanup to
`started/paused/cancelled/resumed/reactivated` — `updated` is absent, so the dead webhook
survives uninstall and keeps firing at a 404 for a company that no longer has the droplet.

**Not verified:** how many `subscription.updated` 404s production has logged. Query Cloud
Logging for `httpRequest.requestUrl=~"/webhook/cart_item_updated"`.

### F5 — The shared webhook token authenticates a webhook about any company. *(high — the fleet pattern)*

`app/controllers/webhooks/base_controller.rb:19-32` and, identically,
`webhooks_controller.rb:50-60`:

```ruby
auth_header = request.headers["AUTH_TOKEN"] || request.headers["X-Auth-Token"] || request.env["HTTP_AUTH_TOKEN"]
webhook_auth_token = Setting.fluid_webhook.auth_token

auth_header.present? && [ webhook_auth_token, company.webhook_verification_token ].include?(auth_header)
```

`Setting.fluid_webhook.auth_token` is one droplet-wide value (seeded as `"change-me"`,
`lib/tasks/settings.rb:199`, editable at `/admin/settings`). `find_company` takes the company from
the caller's payload (`base_controller.rb:26-32`). So a single shared token authenticates a
webhook **about any company** — flipping any customer of any installation between preferred and
retail pricing via `Webhooks::BaseService#set_customer_type`.

Two aggravations: it is `include?`, not `secure_compare` (contrast
`admin_api/companies_controller.rb:36`, which gets this right); and the shared token is rendered
into a form input on the Devise-guarded `/admin/settings` page.

**Fix:** Phase 0, then Phase 5.

### F6 — Full webhook payloads, including credentials, are logged. *(medium)*

`app/jobs/droplet_uninstalled_job.rb:14` and `app/jobs/droplet_reinstalled_job.rb:10`:

```ruby
Rails.logger.warn("[DropletUninstalledJob] Company not found for payload: #{get_payload.inspect}")
```

The install/uninstall payload carries `authentication_token` and `webhook_verification_token`
(`droplet_installed_job.rb:10-11`). `config/initializers/filter_parameter_logging.rb` filters
Rails' own params logging and does nothing about a manual `.inspect`. Also
`fluid_client.rb:61` interpolates the entire Fluid response body into the raised exception
message, which then reaches logs and Sentry through every `rescue => e … e.message` handler; and
`exigo_client.rb:197` does the same for Exigo.

**Fix:** redact before logging. #200's `describeError` / `redactValue` do this.

### F7 — `Callback.name` uniqueness is model-only. *(low)*

`app/models/callback.rb:4` declares `validates :name, uniqueness: true`, but there is no unique
index on `callbacks.name` in `db/schema.rb` or in `20250729195559_create_callbacks.rb`.
`CallbackSyncService` upserts with `find_or_initialize_by(name:)`
(`callback_sync_service.rb:31`), so two concurrent syncs can create duplicate rows — and
`register_active_callbacks` would then register the same definition twice, which Fluid rejects
with a 409 (`CreateAction:28-33`). **Do not add `@unique` in Prisma to fix this** (§4.2); it is a
Rails migration, separately.

### F8 — `installed_callback_ids` is only written when at least one registration succeeded. *(low)*

`app/jobs/droplet_installed_job.rb:153-155`. A partial failure — say four of nine registrations
succeed — writes those four and silently drops the record of the failures, so uninstall leaves
five live registrations behind pointing at a droplet that is gone. Phase 3's rollback discipline
plus Phase 5's uninstall path should record every attempt.

### F9 — `ExigoClient` does not use bind parameters. *(medium)*

`app/clients/exigo_client.rb:124-154` builds `DECLARE @paramN <type> = <literal>` by string
interpolation and prepends it to the query; the only defence is `quote_value`'s
`gsub("'", "''")` (`:231-248`). Inputs include a customer email taken from a cart payload
(`customer_has_active_autoship_by_email?`, `:84-96`) — which, given F1, is attacker-controlled.
The Node port must use real parameter binding.

### F10 — `WebhookEventJob#find_company` keys on the droplet's uuid, not the installation's. *(medium — the fleet pattern, inherited from the template)*

`app/jobs/webhook_event_job.rb:42-47` — byte-identical to `droplet-template@def6b9d`:

```ruby
def find_company
  uuid = @payload.dig("company", "company_droplet_uuid")
  fluid_company_id = @payload.dig("company", "fluid_company_id")

  Company.find_by(company_droplet_uuid: uuid) || Company.find_by(fluid_company_id: fluid_company_id)
end
```

`companies.company_droplet_uuid` holds the **droplet's** uuid, not the installation's:
`droplet_installed_job.rb:29` writes `company.company_droplet_uuid = company_attributes.fetch("droplet_uuid")`,
and `droplet_uuid` identifies the droplet, so the column holds the same value on every row. With
two or more installed companies, `find_by(company_droplet_uuid: …)` returns an **arbitrary** one.

There is a second-order detail that makes this *less* live here than in the fleet generally, and
it should be stated rather than assumed: Fluid's `Droplet::InstallationBlueprint`
(`fluid app/serializers/droplet/installation_blueprint.rb:8, 51, 64, 79, 94, 105`) emits
`droplet_uuid` and **never** `company_droplet_uuid`, so `@payload.dig("company","company_droplet_uuid")`
is `nil` and the first lookup becomes `find_by(company_droplet_uuid: nil)`. That matches any row
whose column is NULL — and the column is nullable in the database even though `Company` validates
its presence. So the failure is: it silently returns a NULL-uuid company if one exists, otherwise
falls through to the correct `fluid_company_id` lookup.

Blast radius is bounded because `DropletInstalledJob#process_webhook` ignores `@company` and does
its own `find_by(fluid_shop:)` (`droplet_installed_job.rb:19`). Only `DropletUninstalledJob` and
`DropletReinstalledJob` act on it — so the realistic outcome is uninstalling the wrong company's
callbacks and webhooks.

**Fix is upstream.** #200 already replaces this with `src/lib/handlers/find-company.ts`, which
tries `droplet_installation_uuid` first and uses `findFirst` because none of these columns is
uniquely indexed (§4.2). It arrives with Phase 1; do not re-implement the Ruby version.

**Not verified:** whether any production `companies` row has a NULL `company_droplet_uuid`, or how
many companies have the droplet installed. Both are single queries; see §9.

### F11 — A latent double render in the `dri` filters. *(informational)*

`customers_controller.rb:42-54` and `price_types_controller.rb:66-78` both `render` on a blank
`dri` and then fall through to `Company.find_by(nil)` and a second `render`, which would raise
`AbstractController::DoubleRenderError`. It is **currently unreachable**: the preceding
`store_dri_in_session` filter already halts the chain in that case. Noted so the Next port does
not faithfully reproduce a bug, and so nobody reports it as live.

---

## 8. The sibling worktree is 42 behind, 2 ahead, and its 2 commits are already superseded

`droplet-dynamic-pricing.claude-fix-zero-price-on-subscription-removed` is on branch
`claude/fix-zero-price-on-subscription-removed`, **42 commits behind `origin/main` and 2 ahead**
(`fe5fe40` "fix(pricing): prevent $0 cart items from bundle subscription removal", `a4ec4b8`
rubocop). Its diff touches only `app/services/callbacks/base_service.rb` and its test.

**Everything it does is already on `origin/main`, in a more developed form.** Its zero-price
guard is `origin/main`'s `base_service.rb:422-430` verbatim. Its `item["subscription_price"].to_f.nonzero? || item["price"]`
fallback has been superseded by `nonzero_price(item["subscription_price"]) || bundle_group_base_price(item) || item["price"]`
(`:442-444`), which is a strict superset — it adds Fluid's own bundle figure as an intermediate
step, which the branch's version does not have.

**Nothing needs to be carried over. The branch should be deleted, not merged.** If it is merged
as-is it will *regress* `cart_items_with_subscription_price` and `cart_items_with_regular_price`
back to the pre-bundle behaviour and drop the `country_safe_price` guard entirely.

---

## 9. Open questions — what I could not verify

- **How many companies have this droplet installed.** F1, F2 and F5 are all cross-tenant bugs;
  with one installation they are latent, with two they are live. I did not query production.
  Check `SELECT count(*) FROM companies WHERE active AND uninstalled_at IS NULL`.
- **Whether any `companies` row has a NULL `company_droplet_uuid`** (F10). One query:
  `SELECT count(*) FROM companies WHERE company_droplet_uuid IS NULL`.
- **Whether `subscription.updated` 404s appear in production logs** (F4), and how many.
- **The production values of `Setting.host_server.base_url` and `Setting.fluid_api.base_url`.**
  Seeded defaults are `http://localhost:3000` and `https://api.fluid.com`
  (`lib/tasks/settings.rb:39, 60`), both editable at `/admin/settings`. The subscription webhook
  URLs are built from `host_server.base_url` (`droplet_installed_job.rb:67`), so the cutover in
  Phase 5 depends on what it actually holds.
- **Whether `Setting.fluid_webhook.auth_token` is still `"change-me"`** in production (F5).
- **Which of the nine `Callback` rows are actually `active`** in production. The registration set
  is operator-configured, not code — Phases 8–10 are scoped by whatever that table says.
- **Whether the droplet-lifecycle webhook is delivered on the v1 or v2 contract.** Fluid's
  `Droplet::WebhookNotifier` branches on `installation.droplet.v2_lifecycle?`
  (`fluid app/models/droplet/webhook_notifier.rb:107-120`) and the v2 path carries an
  `exchange_token` instead of an `authentication_token`. `DropletInstalledJob` reads
  `authentication_token`, so this droplet is presumably on v1 — but that should be confirmed
  before Phase 5 ports the install handler.
- **The p95 latency of each callback today.** Needed as the Phase 10 baseline. New Relic
  `CallbackRequest` custom events carry `definition`, `company_id`, `duration_ms` and `status`
  (`fluid app/lib/callback/client.rb:279-293`).

---

## 10. Summary of load-bearing decisions

| Decision | Rationale | §  |
|---|---|---|
| Eight callback routes fail **closed**, with no `on*` overrides | Fluid discards their status; failing closed is the only thing that produces an alert | 3.2 |
| `cart_email_on_create` fails **open** with `{success: true}` and no `metadata` | Its response *is* applied to `cart.metadata` | 3.2 |
| Translate `db/schema.rb`; no `prisma db pull` | Schema and migrations reconcile exactly, all 11 tables | 4.1 |
| `companies.company_droplet_uuid` and `integration_settings.company_id` stay **non-unique** | `db push` against a live table; this is the #200 `b11972f` bug | 4.2 |
| `exigo_autoship_snapshots.external_ids` gets `@db.Json` | Rails declared `t.json`, not `t.jsonb` | 4.3 |
| The SDK is **vendored**, not from GitHub Packages | The `fluid-studios` npm scope has no matching GitHub org; publishing 403s | 5 / Ph2 |
| Cut over **one definition at a time by editing a registration URL** | Revert is a data edit, not a deploy; Rails stays correct throughout | 5 |
| The pricing engine is ported as a **pure library with a differential harness** before any route | 900 lines of incident-driven edge cases; "looks right" is not a standard for cart prices | 5 / Ph7 |
| Handlers run **inline**; no Solid Queue | Fluid already retries; three databases disappear | 6 |
| `ExigoClient#update_customer_type` is ported **dead** | It is commented out in Rails; enabling it is a product decision | 6 |
| The Rails app is **not deleted** in the migration PR | Unreviewable and unrevertable otherwise | 5 / Ph11 |
