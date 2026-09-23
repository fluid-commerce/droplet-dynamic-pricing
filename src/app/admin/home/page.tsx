/**
 * GET /admin/home — Admin::HomeController#index.
 *
 * `dri`-authenticated, not session-authenticated, despite the /admin prefix.
 * The exemption is in src/middleware.ts; the tenancy note is in
 * src/lib/dashboard/query.ts.
 */

import { CompanyNotFound } from "@/components/dashboard/not-found-notice";
import { loadHome } from "@/lib/dashboard/screens";
import { firstValue, type RawSearchParams } from "@/lib/dashboard/searchparams";

export const dynamic = "force-dynamic";

const CARDS = [
  { key: "total_preferred", label: "Upgraded to preferred" },
  { key: "total_retail", label: "Downgraded to retail" },
  { key: "preferred_pricing_applied", label: "Carts priced as preferred" },
  { key: "total_cart_events", label: "Cart events" },
] as const;

export default async function AdminHomePage({
  searchParams,
}: {
  searchParams: Promise<RawSearchParams>;
}) {
  const data = await loadHome(firstValue(await searchParams, "dri"));
  if (!data) return <CompanyNotFound />;

  return (
    <main className="mx-auto max-w-6xl p-6">
      <h1 className="text-3xl font-bold tracking-tight">Dynamic Pricing</h1>
      <p className="mt-1 text-sm text-muted-foreground">{data.companyName}</p>

      <dl className="mt-8 grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-4">
        {CARDS.map((card) => (
          <div key={card.key} className="rounded-lg border bg-card p-5">
            <dt className="text-sm text-muted-foreground">{card.label}</dt>
            <dd className="mt-2 text-3xl font-semibold tabular-nums">
              {data.stats[card.key].toLocaleString()}
            </dd>
          </div>
        ))}
      </dl>
    </main>
  );
}
