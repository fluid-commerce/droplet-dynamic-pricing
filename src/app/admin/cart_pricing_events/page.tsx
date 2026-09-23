/**
 * GET /admin/cart_pricing_events — Admin::CartPricingEventsController#index.
 *
 * Port of app/views/admin/cart_pricing_events/index.html.erb, markup and
 * classes as they were, in the public_dashboard layout.
 */

import { ListHeader, ListPagination } from "@/components/dashboard/rails-list-parts";
import { CompanyNotFound } from "@/components/dashboard/not-found-notice";
import { PublicDashboardLayout } from "@/components/layouts/rails-layouts";
import {
  humanize,
  numberWithPrecision2,
  railsDate,
  railsTime,
} from "@/lib/dashboard/rails-format";
import { loadCartPricingEvents } from "@/lib/dashboard/screens";
import { firstValue, type RawSearchParams } from "@/lib/dashboard/searchparams";

export const dynamic = "force-dynamic";

const BADGE = "inline-flex items-center px-2 py-1 text-xs font-medium rounded";

/** The ERB's `case event.event_type`. */
function EventTypeBadge({ type }: { type: string | null }) {
  switch (type) {
    case "cart_created":
      return <span className={`${BADGE} bg-blue-50 text-blue-700`}>Cart Created</span>;
    case "item_added":
      return <span className={`${BADGE} bg-green-50 text-green-700`}>Item Added</span>;
    case "item_updated":
      return <span className={`${BADGE} bg-yellow-50 text-yellow-700`}>Item Updated</span>;
    default:
      return (
        <span className={`${BADGE} bg-gray-100 text-gray-700`}>{humanize(type)}</span>
      );
  }
}

export default async function CartPricingEventsPage({
  searchParams,
}: {
  searchParams: Promise<RawSearchParams>;
}) {
  const params = await searchParams;
  const dri = firstValue(params, "dri");
  const data = await loadCartPricingEvents(dri, firstValue(params, "page"));
  if (!data || !dri) return <CompanyNotFound />;

  return (
    <PublicDashboardLayout>
      <ListHeader
        title="Cart Preferred Pricing Events"
        companyName={data.companyName}
        dri={dri}
      />

      {/* Stats Cards */}
      <div className="grid grid-cols-2 gap-4 mb-6">
        <div className="rounded-lg p-4 border border-purple-200 bg-purple-50">
          <div className="text-sm text-purple-700 mb-1">Preferred Applied</div>
          <div className="text-2xl font-bold text-purple-900">
            {data.stats.preferred_applied_count}
          </div>
          <div className="text-xs text-purple-600 mt-1">carts</div>
        </div>

        <div className="bg-white rounded-lg p-4 border border-gray-200">
          <div className="text-sm text-gray-500 mb-1">Total Events</div>
          <div className="text-2xl font-bold text-gray-900">
            {data.stats.total_events}
          </div>
          <div className="text-xs text-gray-400 mt-1">all time</div>
        </div>
      </div>

      {/* Events Table */}
      <div className="bg-white rounded-lg border border-gray-100">
        <table className="w-full">
          <thead className="bg-slate-50 border-b border-gray-400">
            <tr>
              <th className="pl-4 py-3 text-left text-slate-600">Date/Time</th>
              <th className="px-4 py-3 text-left text-slate-600">Cart ID</th>
              <th className="px-4 py-3 text-left text-slate-600">Email</th>
              <th className="px-4 py-3 text-left text-slate-600">Event Type</th>
              <th className="px-4 py-3 text-left text-slate-600">Items</th>
              <th className="px-4 py-3 text-left text-slate-600">Cart Total</th>
              <th className="pr-4 py-3 text-left text-slate-600">Status</th>
            </tr>
          </thead>
          <tbody>
            {data.events.length === 0 ? (
              <tr>
                <td colSpan={7} className="text-center py-12 text-gray-400">
                  <svg
                    className="mt-6 mb-6 w-12 h-12 mx-auto text-gray-300"
                    fill="none"
                    stroke="currentColor"
                    viewBox="0 0 24 24"
                    aria-hidden="true"
                  >
                    <path
                      strokeLinecap="round"
                      strokeLinejoin="round"
                      strokeWidth={2}
                      d="M3 3h2l.4 2M7 13h10l4-8H5.4M7 13L5.4 5M7 13l-2.293 2.293c-.63.63-.184 1.707.707 1.707H17m0 0a2 2 0 100 4 2 2 0 000-4zm-8 2a2 2 0 11-4 0 2 2 0 014 0z"
                    />
                  </svg>
                  <p className="font-medium">No cart pricing events yet</p>
                  <p className="text-sm mt-1 mb-6">
                    Cart pricing events will appear here when customers interact
                    with carts
                  </p>
                </td>
              </tr>
            ) : (
              data.events.map((e) => (
                <tr
                  key={e.id}
                  className="odd:bg-white even:bg-slate-50 hover:bg-slate-100 border-b border-gray-100"
                >
                  <td className="pl-4 py-3 text-gray-700 text-sm">
                    {railsDate(e.created_at)}
                    <span className="text-gray-400 block text-xs">
                      {railsTime(e.created_at)}
                    </span>
                  </td>
                  <td className="px-4 py-3 text-gray-700 font-mono text-sm">
                    {e.cart_id ?? "-"}
                  </td>
                  <td className="px-4 py-3 text-gray-700 text-sm">
                    {e.email_safe || "-"}
                  </td>
                  <td className="px-4 py-3">
                    <EventTypeBadge type={e.event_type} />
                  </td>
                  <td className="px-4 py-3 text-gray-700 text-sm">
                    {e.items_count ?? 0}
                  </td>
                  <td className="px-4 py-3 text-gray-700 text-sm">
                    {e.cart_total !== null && e.cart_total !== ""
                      ? `$${numberWithPrecision2(e.cart_total)}`
                      : "-"}
                  </td>
                  <td className="pr-4 py-3">
                    {e.preferred_pricing_applied ? (
                      <span className="inline-flex items-center text-purple-600 text-sm font-medium">
                        Preferred Applied
                      </span>
                    ) : (
                      <span className="inline-flex items-center text-gray-500 text-sm font-medium">
                        Removed Pricing
                      </span>
                    )}
                  </td>
                </tr>
              ))
            )}
          </tbody>
        </table>

        <ListPagination
          path="/admin/cart_pricing_events"
          dri={dri}
          page={data.page}
          perPage={data.perPage}
          shown={data.events.length}
          totalCount={data.totalCount}
          totalPages={data.totalPages}
          noun="events"
        />
      </div>
    </PublicDashboardLayout>
  );
}
