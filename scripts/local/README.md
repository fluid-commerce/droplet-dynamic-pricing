# Running this droplet locally

```bash
docker run -d --name dp-postgres \
  -e POSTGRES_USER=fluid -e POSTGRES_PASSWORD=fluid_dev_password \
  -e POSTGRES_DB=dynamic_pricing_dev -p 55432:5432 postgres:17

cp .env.example .env.local          # then fill it in; see below
pnpm db:push
pnpm exec tsx scripts/local/seed-dev.ts
pnpm dev
```

The seed empties every table it seeds before inserting its fixtures, so it
refuses to run against anything it cannot confirm is a local development
database: the
host must be this machine AND the database name must contain `dev`,
`development`, `test` or `local`. A Cloud SQL proxy listening on localhost is
therefore still refused — that is the accident being guarded against, not an
edge case. See `guard-local-db.ts`.

`.env.local` needs at minimum:

```
DATABASE_URL=postgresql://fluid:fluid_dev_password@localhost:55432/dynamic_pricing_dev
FLUID_DROPLET_URL=http://localhost:3017
FLUID_WEBHOOK_AUTH_TOKEN=local-shared-webhook-token
FLUID_DROPLET_WEBHOOK_SECRET=local-droplet-webhook-secret
DROPLET_UUID=drp_local_test
AUTH_SECRET=local-dev-auth-secret-not-a-real-one
ADMIN_API_TOKEN=local-admin-api-token
```

**Port 55432, not 5432.** A shell that already exports `DATABASE_URL` — which
this monorepo's setup commonly does, pointing at the shared `fluid_studios`
database — beats `.env.local`, because a real environment variable wins over a
dotenv file. Two symptoms, both confusing: "User was denied access on the
database `(not available)`" at boot, or, worse, a dev server quietly reading
production-shaped data. If you hit either, start the server with the variable
set explicitly:

```bash
DATABASE_URL=postgresql://fluid:fluid_dev_password@localhost:55432/dynamic_pricing_dev pnpm dev
```

## What the seed gives you

One company, `dri_local_test`, plus 23 cart pricing events, 14 customer type
transactions, two price types, an integration setting carrying deliberately
obvious fake secrets, and an admin user. It wipes those tables first, so it is
re-runnable.

| Screen               | URL                                             | Auth               |
| -------------------- | ----------------------------------------------- | ------------------ |
| Dropzone embed       | `/dashboard?dri=dri_local_test`                 | `dri`              |
| Stats                | `/admin/home?dri=dri_local_test`                | `dri`              |
| Cart events          | `/admin/cart_pricing_events?dri=dri_local_test` | `dri`              |
| Transactions         | `/admin/transactions?dri=dri_local_test`        | `dri`              |
| Integration settings | `/admin/integration_setting?dri=dri_local_test` | `dri`              |
| Price types          | `/price_types?dri=dri_local_test`               | `dri`, then cookie |
| Customers            | `/customers?dri=dri_local_test`                 | `dri`, then cookie |
| Admin                | `/admin` → `/login`                             | session            |

Admin login: `admin@local.test` / `password123`.

`/customers` answers 500 against a seeded token, because it lists customers from
the live Fluid API and the seed's `dit_local_fake_token` gets a 401. Rails did
not rescue in `index` either, so that is parity rather than a defect — point it
at a real company token to exercise the screen.

## Worth checking by hand

The integration settings screen must never send the Exigo passwords to the
browser:

```bash
curl -s "http://localhost:3017/admin/integration_setting?dri=dri_local_test" \
  | grep -c "THIS-MUST-NEVER-REACH-THE-BROWSER"   # must print 0
```
