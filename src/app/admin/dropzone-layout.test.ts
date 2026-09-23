/**
 * Every screen in this droplet authenticates on `dri`, and nothing may
 * reintroduce a session.
 *
 * The Rails original had two auth models under one prefix: a Devise session for
 * the real admin, and a `dri` for the screens Fluid embeds. The port carried
 * both across, and the split was fragile in a way a unit test could not see — a
 * server layout higher up the route tree runs regardless of any middleware
 * exemption, and `src/app/admin/layout.tsx` once wrapped all of `/admin/*` and
 * redirected to `/login`, which would have rendered a login page inside Fluid's
 * iframe.
 *
 * The session is gone now: no other droplet in the fleet has one, and the whole
 * flow — next-auth, bcrypt, the users table, the login page, the middleware —
 * was removed rather than kept working. So the invariant simplifies, and these
 * tests hold the simplification in place:
 *
 *   1. every admin screen still exists where the dropzone expects it
 *   2. no layout above any of them redirects a signed-out visitor
 *   3. every one of them actually reads a `dri`, so a new screen cannot be
 *      added unguarded by copying a neighbour
 *   4. nothing in the source imports a session library again
 *   5. no `dri`-authorised code touches a row that has no `company_id`
 *
 * The fifth is the one that cost something. A `dri` proves an installation
 * exists; it does not say which company is asking, and it travels in a query
 * string inside an iframe every merchant admin can read. Against a
 * company-scoped row that is fine. Against a row with no `company_id` — one row
 * for the whole droplet — it means one tenant rewriting what every other
 * tenant's pricing runs through. Rails kept those screens behind the Devise
 * session, so dropping the session and moving everything to `dri` silently
 * opened them.
 *
 * Both are now out of reach rather than re-guarded, because neither table
 * exists. `callbacks` became `droplet.config.ts`, registered at install.
 * `settings` held four rows: two nobody read, and two whose values now come
 * from env (`FLUID_API_URL`, `DROPLET_UUID`, `LEGACY_RAILS_ORIGIN`) — the rest
 * of its machinery was reachable only from the "Create Droplet" screen this
 * migration removed.
 *
 * So the schema has no droplet-global row left at all, and the test asserts
 * that from the schema rather than from a list: a new unscoped model fails it
 * the first time a screen touches one.
 */

import { existsSync, readFileSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";

import { describe, it, expect } from "vitest";

const APP_DIR = join(import.meta.dirname, "..");
const SRC_DIR = join(APP_DIR, "..");

/** Every screen, all of which authenticate on `dri`. */
const SCREENS = [
  "page.tsx",
  "dashboard/page.tsx",
  "price_types/page.tsx",
  "price_types/new/page.tsx",
  "price_types/[id]/edit/page.tsx",
  "customers/page.tsx",
  "admin/home/page.tsx",
  "admin/transactions/page.tsx",
  "admin/cart_pricing_events/page.tsx",
  "admin/integration_setting/page.tsx",
  "admin/integration_setting/edit/page.tsx",
];

/** Every layout.tsx from a page's own directory up to the app root. */
function layoutsAbove(pagePath: string): string[] {
  const found: string[] = [];
  let dir = dirname(join(APP_DIR, pagePath));

  while (dir.startsWith(APP_DIR)) {
    const layout = join(dir, "layout.tsx");
    if (existsSync(layout)) found.push(layout);
    if (dir === APP_DIR) break;
    dir = dirname(dir);
  }

  return found;
}

function redirectsWhenSignedOut(layoutPath: string): boolean {
  const source = readFileSync(layoutPath, "utf8");
  return source.includes("redirect(") && source.includes("auth()");
}

function walk(dir: string): string[] {
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const full = join(dir, entry.name);
    if (entry.isDirectory()) return walk(full);
    return /\.tsx?$/.test(entry.name) ? [full] : [];
  });
}

describe("every screen is reachable and unguarded by a session", () => {
  it.each(SCREENS)("%s", (page) => {
    expect(
      existsSync(join(APP_DIR, page)),
      `${page} does not exist — update this list if the route moved`,
    ).toBe(true);

    expect(
      layoutsAbove(page).filter(redirectsWhenSignedOut),
      `${page} renders inside Fluid's iframe, but a layout above it redirects ` +
        `a signed-out visitor to a login page`,
    ).toEqual([]);
  });
});

describe("every screen authenticates on dri", () => {
  it.each(SCREENS)("%s", (page) => {
    const source = readFileSync(join(APP_DIR, page), "utf8");

    expect(
      source.includes("dri"),
      `${page} never reads a \`dri\`. Every screen here is embedded by Fluid ` +
        `and there is no session to fall back on, so this one is open.`,
    ).toBe(true);
  });
});

describe("the session stays gone", () => {
  const BANNED = [
    "next-auth",
    "@/lib/auth/require",
    "@/lib/auth/password",
    "@/lib/users",
  ];

  it.each(BANNED)("nothing imports %s", (specifier) => {
    const offenders = walk(SRC_DIR).filter((file) => {
      // This file names them on purpose.
      if (file.endsWith("dropzone-layout.test.ts")) return false;
      return readFileSync(file, "utf8").includes(`"${specifier}`);
    });

    expect(
      offenders.map((f) => f.replace(SRC_DIR, "src")),
      `${specifier} belongs to the login flow, which this droplet does not have`,
    ).toEqual([]);
  });
});

/**
 * Models with no company scope, read out of prisma/schema.prisma rather than
 * listed here.
 *
 * The list version needed editing whenever a model was added, which is exactly
 * when it would be forgotten. Parsing the schema means a new unscoped model
 * fails this the first time a screen touches it, with no maintenance.
 */
function unscopedModels(): string[] {
  const schema = readFileSync(
    join(SRC_DIR, "..", "prisma", "schema.prisma"),
    "utf8",
  );

  const models: string[] = [];
  for (const match of schema.matchAll(/^model (\w+) \{([\s\S]*?)^\}/gm)) {
    const [, name, body] = match;
    if (!/\bcompanyId\b/.test(body) && !/^\s*company\s+Company/m.test(body)) {
      models.push(name);
    }
  }
  return models;
}

/** The Prisma delegate name for a model: first letter lowercased. */
function delegate(model: string): string {
  return model.charAt(0).toLowerCase() + model.slice(1);
}

/**
 * The two unscoped models a `dri` screen may legitimately touch, and why.
 *
 *  - `Company` is the tenant table. Its rows ARE companies, and resolving a
 *    `dri` to one is what every screen does first.
 *  - `FluidCallbackRegistration` is keyed by `dri`. Installation-scoped is
 *    company-scoped by another name.
 *
 * Anything else unscoped is one row for the whole droplet, and a screen
 * reaching it is one tenant acting on every tenant.
 */
const TENANT_MODELS = ["Company", "FluidCallbackRegistration"];

const PRISMA_METHODS = [
  "create",
  "createMany",
  "update",
  "updateMany",
  "upsert",
  "delete",
  "deleteMany",
  "findFirst",
  "findMany",
  "findUnique",
  "findUniqueOrThrow",
  "count",
];

/**
 * Where an unscoped access is allowed to live: the operator namespace, and the
 * `src/lib` modules the install and callback paths call. `src/lib` is trusted
 * because nothing there authorises anything — it is reached through a route,
 * and the routes are what this asserts about.
 */
const GLOBAL_WRITE_ALLOWED = [
  join(SRC_DIR, "app", "api", "admin-api"),
  join(SRC_DIR, "lib"),
];

describe("no dri-authorised code touches a droplet-global row", () => {
  it("has no unscoped model beyond the tenant tables", () => {
    // If this fails, a model was added with no company scope. Decide where it
    // is reachable from BEFORE a screen touches it, then either scope it or add
    // it to TENANT_MODELS with the reason.
    expect(unscopedModels().sort()).toEqual([...TENANT_MODELS].sort());
  });

  it("finds no screen touching one", () => {
    const suspect = unscopedModels().filter(
      (model) => !TENANT_MODELS.includes(model),
    );

    const offenders = walk(join(SRC_DIR, "app"))
      .filter(
        (file) => !file.endsWith(".test.ts") && !file.endsWith(".test.tsx"),
      )
      .filter((file) => !GLOBAL_WRITE_ALLOWED.some((d) => file.startsWith(d)))
      .flatMap((file) => {
        const source = readFileSync(file, "utf8");
        return suspect.flatMap((model) =>
          PRISMA_METHODS.filter((method) =>
            source.includes(`prisma.${delegate(model)}.${method}(`),
          ).map(
            (method) =>
              `${file.replace(SRC_DIR, "src")}: prisma.${delegate(model)}.${method}`,
          ),
        );
      });

    expect(
      offenders,
      "These touch a row shared by every company from a screen that authorises " +
        "on a `dri` — which any merchant admin can read out of the iframe URL. " +
        "A droplet-global row belongs in src/app/api/admin-api/, behind " +
        "authorizeAdminApi(), or in env.",
    ).toEqual([]);
  });

  it("is actually looking at the screens", () => {
    // Guards the guard: if the walk or the filters stop matching anything, the
    // assertions above pass for the wrong reason.
    const scanned = walk(join(SRC_DIR, "app")).filter(
      (file) => !GLOBAL_WRITE_ALLOWED.some((d) => file.startsWith(d)),
    );
    expect(scanned.length).toBeGreaterThan(10);
    expect(scanned.some((f) => f.includes("integration_setting"))).toBe(true);
    expect(scanned.some((f) => f.includes("customers"))).toBe(true);
  });
});

describe("the operator namespace authenticates every route", () => {
  const routes = walk(join(SRC_DIR, "app", "api", "admin-api")).filter((file) =>
    file.endsWith("route.ts"),
  );

  it("finds the routes", () => {
    // Guards the guard: an empty walk would make the assertion below vacuous.
    // One route as of the nightly sync's removal — `company` — so this is a
    // floor, not a count.
    expect(routes.length).toBeGreaterThanOrEqual(1);
  });

  it.each(routes.map((f) => [f.replace(SRC_DIR, "src"), f]))(
    "%s checks the bearer token",
    (_label, file) => {
      const source = readFileSync(file, "utf8");
      expect(
        source.includes("authorizeAdminApi("),
        "Every route in admin-api carries a global write or a global job. " +
          "There is no middleware and no session, so a route that does not " +
          "call authorizeAdminApi() is open to the internet.",
      ).toBe(true);
    },
  );
});
