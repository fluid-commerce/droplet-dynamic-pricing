import { prisma } from "@/lib/db";

/**
 * Tenancy for the admin screens, by `dri`.
 *
 * These screens used to sit behind a Devise-style session ported from Rails —
 * a login page, a users table, next-auth and bcrypt. No other droplet in the
 * fleet carries one: a droplet's admin surface is its dropzone, embedded by
 * Fluid, and Fluid identifies the caller with the droplet installation UUID it
 * appends to the iframe URL. The session was dropped to match, and this is what
 * replaced it.
 *
 * What it proves is modest and worth stating plainly: that the caller knows a
 * `dri` belonging to an installation of this droplet. It is a lookup key, not a
 * credential — it travels in a query string, so it reaches browser history,
 * referrers and anyone the merchant shares a link with. It is the same bar the
 * other screens here already sit behind; it is not a session.
 *
 * `callbacks` and `settings` read tables that carry no `company_id` — they are
 * global to the droplet, not per-company. The `dri` is therefore doing pure
 * gatekeeping on those screens rather than selecting a tenant, which is why it
 * is resolved and discarded rather than passed down.
 */
export async function driIsInstalled(
  dri: string | undefined,
): Promise<boolean> {
  if (!dri) return false;

  const company = await prisma.company.findFirst({
    // `not: false` rather than `true`: uninstall writes `active: false`, and
    // that is the revocation signal this needs to honour. Matching `true`
    // would also exclude a legacy row whose nullable `active` was never
    // backfilled, locking the dropzone out of a company that is fine.
    where: { dropletInstallationUuid: dri, active: { not: false } },
    select: { id: true },
  });

  return company !== null;
}

/**
 * An admin href that carries the `dri` forward.
 *
 * Every link and redirect between these screens has to, or the next request
 * arrives without one and is refused. The session cookie used to do this
 * silently; a query-string key does not.
 */
export function withDri(
  path: string,
  dri: string | undefined,
  extra: Record<string, string> = {},
): string {
  const query = new URLSearchParams({ ...(dri ? { dri } : {}), ...extra });
  const suffix = query.toString();
  return suffix ? `${path}?${suffix}` : path;
}
