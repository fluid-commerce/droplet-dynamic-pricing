# Rails → Next parity audit (STU2-3356)

Measured against `main` @ `b0cdbcd` on 2026-09-15, by reading both trees rather
than by trusting `MIGRATION.md`, which was written against `5f3b5f9` and is now
47 commits stale.

The question this answers is not "does the Next app work". It is: **if the Rails
service is deleted, what stops happening?**

| | Rails | Next |
|---|---:|---:|
| Application code | 6,321 lines Ruby + 977 lines ERB | 9,792 lines TS/TSX |
| Tests | 78 files | 19 files |

---

## 1. Verdict

**The request path has parity. The merchant-facing and scheduled paths do not.**

| Surface | Parity | Evidence |
|---|---|---|
| 9 callback routes | ✅ complete | `src/lib/pricing/services.ts` exports all 9 |
| 6 webhook routes | ✅ complete | 5 subscription routes + `/api/webhooks` |
| Pricing core (`base_service.rb`, 1124 loc) | ✅ complete | 89 methods cross-checked, §2 |
| Exigo client | ✅ complete | `exigo_client.rb` 268 → `src/lib/exigo/client.ts` 302 |
| Fluid client (10 files) | ✅ complete | → `src/lib/fluid/client.ts` 605 |
| Data layer | ✅ complete | 12/12 Rails tables mapped in `schema.prisma` |
| Session admin (settings, callbacks, users, droplet) | ✅ complete | `/admin/*` pages + server actions |
| Rake tasks | ✅ complete | → `scripts/create-admin.ts`, `create-default-settings.ts` |
| **Dropzone UI (7 units)** | ❌ **absent** | §3 |
| **Nightly Exigo reconciliation** | ❌ **absent** | §4 |
| **`PATCH /admin_api/company`** | ❌ **absent** | §5 |

**929 lines of Ruby and 977 lines of ERB have no counterpart in the Next app.**

---

## 2. The request path — how parity was verified

Not by reading the diff. By extracting every method name from
`app/services/callbacks/base_service.rb`, mapping snake_case → camelCase, and
searching the whole Next pricing tree for each one.

**75 of 89 matched by name.** The 14 that did not were each opened and compared
by behaviour:

| Rails method | Where it went |
|---|---|
| `country_field_iso` | inlined into `get cartPricingCountry` (`context.ts:654`) |
| `row_field` | generalised into the `field()` helper |
| `item_metadata`, `price_field_for` | inlined at their single call sites |
| `preferred_customer_volumes?` | inlined into `cartItemVolumes` |
| `subscriptions_response_usable?` | inlined into `hasActiveSubscriptions` |
| `company_yields_to_enrollment_wholesale?` | read off the injected `settings.yieldToEnrollmentWholesale` |
| `exigo_integration_setting`, `exigo_integration_enabled?` | `src/lib/integration-settings.ts` |
| `find_company` | `src/lib/handlers/find-company.ts` |
| `fluid_members` | accessor on the injected Fluid client |
| `initialize*` (3) | constructor injection via `src/lib/pricing/deps.ts` |

**Zero behavioural gaps.** The port is careful in places the names would not
reveal — `cartPricingCountry` reimplements Ruby's `||` fall-through explicitly,
with a comment on why `??` would be a different charge, because an empty
`country_code` is truthy in Ruby and nullish in TS.

The webhook path checks out the same way: `webhooks/base_service.rb`'s 24
methods are all present in `src/lib/webhooks/subscriptions.ts`, with
`log_transaction`, `preferred_type_id` and `retail_type_id` moved into the
injected `SubscriptionWebhookDeps` rather than dropped.

**One cosmetic defect.** `src/lib/pricing/routes-table.ts:3` says "Two of the
nine Rails routes were named for something OTHER than their Fluid definition"
and names two. There are **three** — it omits `cart_subscription_removed`
(`/callbacks/subscription_removed`). The table itself is correct; only the
comment undercounts. `CUTOVER.md §1` has it right.

---

## 3. Gap A — the dropzone UI (7 units, 421 loc Ruby + 977 loc ERB)

Every merchant-facing screen. None exists in Next.

| Rails | Route | Auth | Ruby |
|---|---|---|---|
| `DynamicPricingDashboardController` | `GET /dashboard` | `dri` param | 50 |
| `Admin::HomeController` | `GET /admin/home` | `dri` param | 29 |
| `Admin::TransactionsController` | `GET /admin/transactions` | `dri` param | 36 |
| `Admin::CartPricingEventsController` | `GET /admin/cart_pricing_events` | `dri` param | 36 |
| `Admin::IntegrationSettingsController` | `GET/PATCH /admin/integration_setting` | `dri` param | 59 |
| `CustomersController` | `GET/PATCH /customers` | `dri` param | 59 |
| `PriceTypesController` (+ 2 use cases) | `/price_types` CRUD | `dri` param | 83 + 69 |

The split is clean and it is visible in the class hierarchy. Everything that
inherits `AdminController` — settings, callbacks, users, dashboard, droplets —
is session-authenticated and **is ported**. Everything that inherits
`PublicAdminController` or `ApplicationController` directly is `dri`-only and
**is not**.

`prisma.priceType` and `prisma.exigoAutoshipSnapshot` have **zero** call sites
in the Next app. The tables are mapped; nothing reads them.

### This blocks Phase 4 of the ticket as written

The ticket says: repoint droplet 165's `embed_url` to the Next `/dashboard`.

**There is no `/dashboard` in the Next app.** The route list is `/`, `/login`,
`/admin/*`, `/api/*`. Repointing the embed today replaces the merchant's
dropzone with a 404.

### Two findings that are not migration concerns

**1. The Exigo production database password is served to anyone holding a `dri`.**

`Admin::IntegrationSettingsController < PublicAdminController` — note the
superclass. There is no `authenticate_user!` anywhere in that chain;
`ApplicationController#set_dri` is just `@dri = params[:dri]`, an unsigned query
parameter. And `_form.html.erb:113`:

```erb
<%= password_field_tag "integration_setting[credentials][exigo_db_password]",
      @integration_setting.credentials["exigo_db_password"], ... %>
```

`password_field_tag` with an explicit value renders `value="…"` into the HTML.
So `GET /admin/integration_setting/edit?dri=<uuid>` returns the Exigo DB host,
name, username and **password**, plus the Exigo API password, with no session.
The `dri` is in the iframe URL of the dropzone, so it is visible to anyone who
opens devtools on the Fluid admin page. `PATCH` on the same route is equally
unauthenticated — that `dri` also lets you *rewrite* a company's Exigo
credentials.

**2. `/price_types` and `/customers` are company-scoped by the same `dri`.**
`CustomersController#update` writes customer records through the company's own
Fluid token. Same exposure, lower blast radius.

Porting these as-is would carry both across. They should be ported *and* fixed
in the same change — the `dri` has to be signed, or exchanged for a session.

---

## 4. Gap B — the nightly Exigo reconciliation (411 loc)

`PreferredCustomerSyncService` (368) + `PreferredCustomerSyncJob` (43).
`grep -rn "PreferredCustomerSync" src/` returns **nothing**.

It runs at midnight, in-process, under Solid Queue inside Puma:

```yaml
# config/recurring.yml
preferred_customer_sync:
  class: PreferredCustomerSyncJob
  schedule: "0 0 * * *"
```
```ruby
# config/puma.rb:22
plugin :solid_queue if ENV["SOLID_QUEUE_IN_PUMA"]
# config/deploy.yml:41
SOLID_QUEUE_IN_PUMA: true
```

### This blocks Phase 5 of the ticket as written

Phase 5 says "Remove `SOLID_QUEUE_IN_PUMA` if present, then `--min-instances=0`",
on the assumption that droplet cron lives in BullMQ in `apps/queue-workers`. For
this droplet it does not — it lives in the Rails process being switched off.
Doing that stops the nightly reconciliation, and nothing reports it. It is the
same failure mode the ticket warns about for callbacks, relocated into the cron.

### It is stateful, which constrains how it can be ported

The service diffs today's Exigo preferred set against `exigo_autoship_snapshots`
(`fetch_yesterday_snapshot` → `run_delta_sync`), with a separate
`run_warmup_sync` path when no usable snapshot exists, a `daily_warmup_limit`,
and `api_delay_seconds` throttling the writes to Fluid and Exigo.

Two consequences:

- **It must never run on both services at once.** Two writers against one
  snapshot table means each sees the other's rows as yesterday's truth, and both
  push customer-type changes to Fluid and Exigo. Unlike the callback cutover,
  this one is not safe to overlap.
- **It cannot be cut over per company.** The callbacks can, because the
  registration table routes per company. This job enumerates
  `Company.active` itself, so it moves all-or-nothing.

---

## 5. Gap C — `PATCH /admin_api/company` (97 loc)

`ADMIN_API_TOKEN` bearer with `secure_compare`, updating `name`, `fluid_shop`
and `active`. Correct as it stands. Ops uses it; nothing in the Next app answers
that path.

---

## 6. Correctly absent — do not port

Stated so nobody reads the absence as a gap.

- **`events` and `webhooks` tables.** Both are mapped in `schema.prisma`, and
  both are dead in Rails: `grep` finds no `Event.` or `Webhook.` call site
  anywhere in `app/`. `app/models/webhook.rb` is two lines. `EventHandler` is a
  class-level router that never touches the `Event` model.
- **`DropletReinstalledJob`.** The handler exists on both sides; neither app
  registers `droplet.reinstalled`, so nothing dispatches to it.
- **`ExigoClient#updateCustomerType` as a live path.** Ported, but both Rails
  call sites are commented out and log `[EXIGO UPDATE DISABLED]`. Enabling it is
  a product decision, not a migration side effect.
- **Solid Cache.** Dropping it moves the preferred-status cache from a shared
  table to per-container memory. Lower hit rate, but the safe direction — a cold
  container spends one extra lookup rather than reading a stale answer.
  `PREFERRED_LOOKUP_TTL_SECONDS` still tunes it.

---

## 7. The known defect, confirmed

`src/app/api/webhooks/route.ts:69` (line 70 at the commit the ticket was written
against):

```ts
bootstrapSecret: process.env.FLUID_WEBHOOK_AUTH_TOKEN,
```

Fluid signs `droplet.installed` / `droplet.uninstalled` with
`droplets.webhook_secret`, not that token. Unfixed, every install and uninstall
401s, and nothing reports it. Envelope handling is already correct
(`effectivePayload`), so only the key is wrong.

---

## 8. What this means for the ticket

The ticket's five phases are sound for the **request path**. Phases 0–3 can run
as written once §7 is fixed. Phases 4 and 5 cannot:

| Phase | Status |
|---|---|
| 0 — baseline | ✅ as written |
| 1 — fix + deploy | ✅ as written (the §7 fix) |
| 2 — prove the work path | ✅ as written |
| 3 — per-company callback cutover | ✅ as written |
| 4 — repoint embed + lifecycle | ⛔ **blocked**: no `/dashboard` exists |
| 5 — retire Rails | ⛔ **blocked**: kills the nightly reconciliation |

Closing the gap is roughly **1,900 lines of Rails to port**, of which the
dropzone UI is the larger half and the reconciliation job is the harder half.

## 9. Suggested order

1. **§7 lifecycle key** — small, blocks everything, already specified.
2. **Phases 0–3** — the callback cutover. Independent of the gap; Rails keeps
   serving the UI and the cron throughout, and rollback stays per company.
3. **`PATCH /admin_api/company`** — 97 lines, no UI, no state. Cheapest gap.
4. **The nightly reconciliation** — hardest, and the only one that cannot be
   split per company. Needs a scheduler decision (Cloud Scheduler against a
   token-guarded route, a Cloud Run Job, or BullMQ) and a hard cutover with the
   Rails job disabled in the same change.
5. **The dropzone UI** — largest, and gated on deciding what replaces the
   unsigned `dri`. Until this lands, Phase 4's embed repoint cannot happen.
6. **Phase 5** — only after 4 and 5 are live and quiet.
