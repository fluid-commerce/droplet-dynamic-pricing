/**
 * Refuses to touch anything that is not a local development database.
 *
 * `seed-dev.ts` opens by emptying every table it seeds. That is correct against
 * a throwaway local database and catastrophic against any other one,
 * and nothing stopped the difference: `scripts/guard-db-push.sh` protects
 * `db:push`, `db:migrate` and `db:studio`, but the seed is documented as
 * `pnpm exec tsx scripts/local/seed-dev.ts` — run directly, past any
 * package.json wrapper. A developer who still had a Cloud SQL proxy up, or an
 * inherited `DATABASE_URL` in their shell, wiped whatever it pointed at.
 *
 * So the check lives in the process that does the deleting. The rules mirror
 * guard-db-push.sh, with one difference: that script guards a schema change and
 * can afford to be permissive, while this one guards a delete and refuses
 * anything it does not positively recognise as local.
 */

/** Hostnames that are a developer's own machine. */
const LOCAL_HOSTS = new Set(["localhost", "127.0.0.1", "::1", "0.0.0.0"]);

/**
 * Substrings that name shared or production infrastructure, from
 * guard-db-push.sh. Checked in addition to the host allowlist, so a tunnel
 * forwarding a shared instance to localhost is still refused — which is exactly
 * the shape a Cloud SQL proxy has.
 */
const FORBIDDEN = [
  "/fluid_studios",
  "fluid-studioz",
  "/cloudsql/",
  "@prod",
  "@production",
  "@staging",
];

export function assertLocalDatabase(url: string | undefined): void {
  if (!url) {
    fail(
      "DATABASE_URL is not set.",
      "Point it at a dedicated local Postgres database for this droplet, e.g.",
      "  DATABASE_URL=postgresql://fluid:fluid_dev_password@localhost:5432/droplet_dynamic_pricing_dev",
    );
  }

  for (const needle of FORBIDDEN) {
    if (url.includes(needle)) {
      fail(
        `DATABASE_URL contains ${JSON.stringify(needle)}, which names shared or production infrastructure.`,
        "This script empties every table it seeds. Refusing.",
      );
    }
  }

  let host: string;
  let database: string;
  try {
    const parsed = new URL(url);
    host = parsed.hostname;
    database = parsed.pathname.replace(/^\//, "");
  } catch {
    fail(
      "DATABASE_URL is not a URL this script can inspect.",
      "It refuses anything it cannot positively confirm is local, because the",
      "first thing it does is empty every table it seeds.",
    );
  }

  if (!LOCAL_HOSTS.has(host)) {
    fail(
      `DATABASE_URL points at host ${JSON.stringify(host)}, not this machine.`,
      "This script empties every table it seeds. Refusing.",
    );
  }

  // A local host is not enough on its own: the usual accident is a proxy on
  // localhost forwarding a real instance. Requiring the database name to say
  // it is a development one makes that accident spell itself out.
  if (!/(^|_)(dev|development|test|local)(_|$)/.test(database)) {
    fail(
      `DATABASE_URL names the database ${JSON.stringify(database)}, which does not look like a development one.`,
      "Expected the name to contain dev, development, test or local — a local",
      "port can be a proxy to somewhere real, and the database name is the only",
      "part of the url that says what it actually is.",
    );
  }
}

function fail(...lines: string[]): never {
  console.error(`\n❌ ${lines[0]}`);
  for (const line of lines.slice(1)) console.error(line);
  console.error("");
  process.exit(1);
}
