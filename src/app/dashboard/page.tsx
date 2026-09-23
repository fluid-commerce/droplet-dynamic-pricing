/**
 * GET /dashboard — kept as a redirect to `/`.
 *
 * This was the embed's path in the standalone repo, where `/` had to serve the
 * Rails sign-in landing. Droplet 165's `embed_url` on the Rails host still ends
 * in `/dashboard`, and `drop_zones`, `mobile_widgets` and
 * `mobile_navigation_items` carry their own `embed_url` values that are not
 * derived from the droplet record — so anything already pointing here keeps
 * working rather than rendering a 404 inside a merchant's panel.
 *
 * The query string is carried through: without the `dri` the destination has no
 * tenant and answers "Company not found".
 */

import { redirect } from "next/navigation";

import type { RawSearchParams } from "@/lib/dashboard/searchparams";

export const dynamic = "force-dynamic";

export default async function DashboardRedirect({
  searchParams,
}: {
  searchParams: Promise<RawSearchParams>;
}) {
  const params = await searchParams;
  const query = new URLSearchParams();

  for (const [key, value] of Object.entries(params)) {
    if (value === undefined) continue;
    query.set(key, Array.isArray(value) ? (value[0] ?? "") : value);
  }

  redirect(query.size > 0 ? `/?${query}` : "/");
}
