/**
 * Bearer authorisation for the `admin-api` namespace.
 *
 * Extracted from `api/admin-api/company/route.ts`, which held the only copy
 * while it and `preferred-customer-sync` were the two operator routes. That
 * second one is gone and `company` is the only one left, so this is now here
 * for the next route rather than for a duplicate — the comparison below is the
 * part worth having exactly one copy of.
 *
 * What this token means, and what the `dri` next to it does not:
 * `driIsInstalled` proves an installation exists, not who is asking — the
 * `dri` rides in a query string inside an iframe every merchant admin can
 * read. That is enough for a screen that only touches the asking company's own
 * rows. It is not enough for a row with no `company_id`, because there every
 * tenant is writing the same record. `ADMIN_API_TOKEN` is held by the people
 * who operate the droplet and never reaches a browser, which is the only
 * reason it can carry a global write.
 */

import { timingSafeEqual } from "node:crypto";

/**
 * Rails used `ActiveSupport::SecurityUtils.secure_compare`, which RAISES on a
 * length mismatch — so a token of the wrong length came back as a 500 rather
 * than a 401. `timingSafeEqual` has the same constraint, so the lengths are
 * checked first and a mismatch is the ordinary refusal. Same answer for every
 * wrong token, which is also what stops the length leaking.
 *
 * An unset `ADMIN_API_TOKEN` authorises nobody. It deliberately does not fall
 * back to "open in development": these routes rewrite configuration every
 * company shares, and a local run points at the same Cloud SQL instance often
 * enough that the safe default is the closed one.
 */
export function authorizeAdminApi(request: Request): boolean {
  const expected = process.env.ADMIN_API_TOKEN;
  if (!expected) return false;

  const provided = request.headers
    .get("authorization")
    ?.replace(/^Bearer /, "");
  if (!provided) return false;

  const a = Buffer.from(provided, "utf8");
  const b = Buffer.from(expected, "utf8");
  return a.length === b.length && timingSafeEqual(a, b);
}

/** The one refusal shape every route in the namespace answers with. */
export function unauthorized(): Response {
  return Response.json({ error: "Unauthorized" }, { status: 401 });
}
