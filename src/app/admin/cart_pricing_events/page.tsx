/**
 * GET /admin/cart_pricing_events — Admin::CartPricingEventsController#index.
 *
 * The underscored path is Rails' and is kept: `drop_zones`, `mobile_widgets`
 * and `mobile_navigation_items` carry their own `embed_url` and are not derived
 * from the droplet record, so a rename would silently break whatever points
 * here.
 */

import { CartEventsTab } from "@/components/dashboard/CartEventsTab";
import { CompanyNotFound } from "@/components/dashboard/not-found-notice";
import { loadCartPricingEvents } from "@/lib/dashboard/screens";
import { PAGE_PLACEHOLDER } from "@/lib/dashboard/page-href";
import { firstValue, type RawSearchParams } from "@/lib/dashboard/searchparams";

export const dynamic = "force-dynamic";

export default async function CartPricingEventsPage({
  searchParams,
}: {
  searchParams: Promise<RawSearchParams>;
}) {
  const params = await searchParams;
  const dri = firstValue(params, "dri");
  const data = await loadCartPricingEvents(dri, firstValue(params, "page"));
  if (!data) return <CompanyNotFound />;

  return (
    <main className="mx-auto max-w-6xl p-6">
      <h1 className="text-3xl font-bold tracking-tight">Cart Pricing Events</h1>
      <p className="mt-1 mb-8 text-sm text-muted-foreground">
        {data.companyName}
      </p>

      <CartEventsTab
        events={data.events}
        preferredAppliedCount={data.stats.preferred_applied_count}
        totalCount={data.totalCount}
        page={data.page}
        perPage={data.perPage}
        pageHrefTemplate={`/admin/cart_pricing_events?${new URLSearchParams({
          dri: dri ?? "",
          page: PAGE_PLACEHOLDER,
        })}`}
      />
    </main>
  );
}
