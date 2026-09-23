/**
 * GET /admin/home — Admin::HomeController#index.
 *
 * Port of app/views/admin/home/index.html.erb, markup and classes as they were,
 * in the public_dashboard layout: the title, the Integration Settings button,
 * and the two cards that are the only way from here to the transactions and
 * cart-events screens.
 */

import { CompanyNotFound } from "@/components/dashboard/not-found-notice";
import { PublicDashboardLayout } from "@/components/layouts/rails-layouts";
import { loadHome } from "@/lib/dashboard/screens";
import { firstValue, type RawSearchParams } from "@/lib/dashboard/searchparams";

export const dynamic = "force-dynamic";

function Chevron() {
  return (
    <svg
      className="w-4 h-4 ml-1"
      fill="none"
      stroke="currentColor"
      viewBox="0 0 24 24"
      aria-hidden="true"
    >
      <path
        strokeLinecap="round"
        strokeLinejoin="round"
        strokeWidth={2}
        d="M9 5l7 7-7 7"
      />
    </svg>
  );
}

export default async function AdminHomePage({
  searchParams,
}: {
  searchParams: Promise<RawSearchParams>;
}) {
  const dri = firstValue(await searchParams, "dri");
  const data = await loadHome(dri);
  if (!data || !dri) return <CompanyNotFound />;

  const q = new URLSearchParams({ dri }).toString();

  return (
    <PublicDashboardLayout>
      <div className="mb-8">
        <div className="flex items-center justify-between mb-6">
          <div className="flex flex-col gap-1">
            <h1 className="font-custom text-4xl font-bold text-gray-600">
              Dynamic Pricing Dashboard
            </h1>
            <h3 className="text-gray-400">{data.companyName}</h3>
          </div>
          <a
            href={`/admin/integration_setting?${q}`}
            className="px-4 py-2 bg-blue-600 hover:bg-blue-700 text-white font-medium rounded-md"
          >
            Integration Settings
          </a>
        </div>

        {/* Navigation Cards */}
        <div className="grid grid-cols-2 gap-6 mb-8">
          {/* Customer Type Transactions Card */}
          <a href={`/admin/transactions?${q}`} className="block">
            <div className="bg-white rounded-lg border-2 border-gray-200 hover:border-blue-400 hover:shadow-lg transition-all p-6">
              <div className="flex items-start justify-between mb-4">
                <div>
                  <h2 className="text-xl font-bold text-gray-800 mb-1">
                    Customer Type Transactions
                  </h2>
                  <p className="text-sm text-gray-500">
                    Track preferred and retail customer type changes
                  </p>
                </div>
                <svg
                  className="w-8 h-8 text-blue-500"
                  fill="none"
                  stroke="currentColor"
                  viewBox="0 0 24 24"
                  aria-hidden="true"
                >
                  <path
                    strokeLinecap="round"
                    strokeLinejoin="round"
                    strokeWidth={2}
                    d="M17 20h5v-2a3 3 0 00-5.356-1.857M17 20H7m10 0v-2c0-.656-.126-1.283-.356-1.857M7 20H2v-2a3 3 0 015.356-1.857M7 20v-2c0-.656.126-1.283.356-1.857m0 0a5.002 5.002 0 019.288 0M15 7a3 3 0 11-6 0 3 3 0 016 0zm6 3a2 2 0 11-4 0 2 2 0 014 0zM7 10a2 2 0 11-4 0 2 2 0 014 0z"
                  />
                </svg>
              </div>

              <div className="grid grid-cols-2 gap-3">
                <div className="bg-green-50 rounded p-3">
                  <div className="text-xs text-green-700 mb-1">Preferred</div>
                  <div className="text-2xl font-bold text-green-900">
                    {data.stats.total_preferred}
                  </div>
                </div>
                <div className="bg-orange-50 rounded p-3">
                  <div className="text-xs text-orange-700 mb-1">Retail</div>
                  <div className="text-2xl font-bold text-orange-900">
                    {data.stats.total_retail}
                  </div>
                </div>
              </div>

              <div className="mt-4 flex items-center text-blue-600 text-sm font-medium">
                View All Transactions
                <Chevron />
              </div>
            </div>
          </a>

          {/* Cart Pricing Events Card */}
          <a href={`/admin/cart_pricing_events?${q}`} className="block">
            <div className="bg-white rounded-lg border-2 border-gray-200 hover:border-purple-400 hover:shadow-lg transition-all p-6">
              <div className="flex items-start justify-between mb-4">
                <div>
                  <h2 className="text-xl font-bold text-gray-800 mb-1">
                    Cart Preferred Pricing
                  </h2>
                  <p className="text-sm text-gray-500">
                    Monitor preferred pricing applications to carts
                  </p>
                </div>
                <svg
                  className="w-8 h-8 text-purple-500"
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
              </div>

              <div className="grid grid-cols-2 gap-3">
                <div className="bg-purple-50 rounded p-3">
                  <div className="text-xs text-purple-700 mb-1">
                    Preferred Applied
                  </div>
                  <div className="text-2xl font-bold text-purple-900">
                    {data.stats.preferred_pricing_applied}
                  </div>
                </div>
                <div className="bg-gray-50 rounded p-3">
                  <div className="text-xs text-gray-500 mb-1">Total Events</div>
                  <div className="text-2xl font-bold text-gray-900">
                    {data.stats.total_cart_events}
                  </div>
                </div>
              </div>

              <div className="mt-4 flex items-center text-purple-600 text-sm font-medium">
                View All Cart Events
                <Chevron />
              </div>
            </div>
          </a>
        </div>
      </div>
    </PublicDashboardLayout>
  );
}
