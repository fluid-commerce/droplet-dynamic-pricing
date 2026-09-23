#!/usr/bin/env bash
# guard-db-push.sh
#
# Refuses to run `prisma db push` (or migrate dev / studio) if DATABASE_URL
# looks like it points at shared or production infrastructure. Stops the
# "I had a Cloud SQL proxy running and my laptop just wrote to prod" class
# of accident.
#
# This script is copied into every new droplet by scripts/create-droplet.ts.
# Keep it permissive enough not to block legitimate local development, but
# strict enough to catch the known foot-guns.

set -euo pipefail

if [[ -f ".env" ]]; then
  # shellcheck disable=SC1091
  set -o allexport
  if ! source .env; then
    echo "❌ guard-db-push: failed to source .env (parse error?). Refusing to run prisma." >&2
    exit 1
  fi
  set +o allexport
fi

if [[ -z "${DATABASE_URL:-}" ]]; then
  cat >&2 <<'EOF'
❌ guard-db-push: DATABASE_URL is not set.

Set it in this droplet's .env file, pointing at a DEDICATED local
Postgres database for this droplet only. Do not reuse another droplet's
DATABASE_URL and do not point at the shared fluid_studios database.

Example (local dev):
  DATABASE_URL=postgresql://fluid:fluid_dev_password@localhost:5432/droplet_mything_dev
EOF
  exit 1
fi

url="$DATABASE_URL"

fail() {
  cat >&2 <<EOF
❌ guard-db-push: refusing to run prisma against this DATABASE_URL.

Reason:   $1
URL host: $(printf '%s' "$url" | sed -E 's|^[^/]+//[^@]*@([^/?]+).*|\1|')
Database: $(printf '%s' "$url" | sed -E 's|^[^/]+//[^/]+/([^?]+).*|\1|')

This script only allows 'prisma db push / migrate dev / studio' against a
local, dedicated development database. Production and shared databases are
managed by CI/CD — not by your laptop.

If you need to inspect shared data, use the droplet's db-connect.sh
wrapper (read-only SQL) or go through a proper migration in CI.
EOF
  exit 1
}

# Reject the shared production database name. The bash glob `*"/fluid_studios"*`
# matches whether the name is followed by `?` (query params), `/` (more path),
# or end-of-string — no second condition needed.
if [[ "$url" == *"/fluid_studios"* ]]; then
  fail "DATABASE_URL targets the shared 'fluid_studios' database (managed by shared-api CI)."
fi

# Reject the shared Cloud SQL instance host/name.
if [[ "$url" == *"fluid-studioz"* ]]; then
  fail "DATABASE_URL mentions the shared 'fluid-studioz' Cloud SQL instance."
fi

# Reject Cloud SQL Unix socket formats (those are only used by CI/Cloud Run).
if [[ "$url" == *"host=/cloudsql/"* ]] || [[ "$url" == *"/cloudsql/"* ]]; then
  fail "DATABASE_URL uses a Cloud SQL unix socket — that's a CI/Cloud Run code path, not local dev."
fi

# Reject obvious Private IP ranges (10.x.x.x commonly used by Cloud SQL Private IP).
if [[ "$url" =~ @10\.[0-9]+\.[0-9]+\.[0-9]+ ]]; then
  fail "DATABASE_URL host is a 10.x.x.x private IP — looks like Cloud SQL Private IP."
fi

# Reject known proxy/prod-ish hostnames.
if [[ "$url" == *"@prod"* ]] || [[ "$url" == *"@production"* ]] || [[ "$url" == *"@staging"* ]]; then
  fail "DATABASE_URL host name contains 'prod', 'production', or 'staging'."
fi

# THIS repo's Next app maps onto the Rails droplet's own database, and its
# Prisma schema deliberately leaves out five tables Rails still reads
# (`settings`, `callbacks`, `users`, `webhooks`, `exigo_autoship_snapshots`).
# A `prisma db push` against the Rails database therefore DROPS them. Rails owns
# that schema and migrates it; this command is for a throwaway local database
# only. The checks above catch shared hosts, but not a proxy on localhost
# forwarding the real instance — the database NAME is the only part of the url
# that says what it is, so it must say development.
db_name="$(printf '%s' "$url" | sed -nE 's|^[a-zA-Z0-9+.-]+://[^@]*@[^/]*/([^?]*).*|\1|p')"
if [[ "$db_name" == "dynamic_pricing" ]]; then
  fail "DATABASE_URL targets 'dynamic_pricing' — the Rails droplet's live database. db push would drop five tables Rails uses."
fi
if ! [[ "$db_name" =~ (^|_)(dev|development|test|local)(_|$) ]]; then
  fail "DATABASE_URL names database '${db_name:-<none>}', which does not look like a development one (expected dev/development/test/local in the name)."
fi

# Everything else is allowed — typically localhost:5432 or 127.0.0.1 or a
# developer-chosen local hostname. We specifically do NOT require the URL
# to contain 'localhost' because some developers use docker-compose with a
# custom hostname like 'postgres' on their dev machines.
