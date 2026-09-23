/**
 * GET / — the droplet's main screen, and the dropzone embed.
 *
 * Port of DynamicPricingDashboardController#index. It lives at the ROOT on
 * purpose: Fluid embeds a droplet at its `embed_url` and appends the
 * installation's `dri`, so that URL is the app's base. A screen parked one path
 * deeper renders an empty iframe, which is indistinguishable from a droplet
 * that failed to boot — the same reasoning as droplet-member-tier's root page.
 *
 * In the standalone repo this was `/dashboard`, because `/` had to serve the
 * Rails app's sign-in landing. There is no Rails here. `/dashboard` still
 * answers, redirecting here with the query intact, so droplet 165's existing
 * Rails-host `embed_url` does not 404 if it is carried over verbatim.
 *
 * Authenticated by the `dri` query parameter alone, as Rails was. That is the
 * embed contract rather than a choice — Fluid's dropzone appends only
 * `public_id`, so the `dri` is baked into the configured `embed_url`. See the
 * tenancy note in src/lib/dashboard/query.ts.
 */

import { Dashboard } from "@/components/dashboard/dashboard";
import { CompanyNotFound } from "@/components/dashboard/not-found-notice";
import { loadDashboard } from "@/lib/dashboard/query";
import { firstValue, type RawSearchParams } from "@/lib/dashboard/searchparams";

export const dynamic = "force-dynamic";

export default async function DropletHomePage({
  searchParams,
}: {
  searchParams: Promise<RawSearchParams>;
}) {
  const params = await searchParams;
  const dri = firstValue(params, "dri");
  const data = await loadDashboard(
    dri,
    firstValue(params, "tab"),
    firstValue(params, "page"),
  );

  if (!data) return <CompanyNotFound />;

  return (
    <main className="mx-auto max-w-6xl p-6">
      <Dashboard {...data} dri={dri ?? ""} />
    </main>
  );
}
