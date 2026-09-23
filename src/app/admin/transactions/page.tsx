/**
 * GET /admin/transactions — Admin::TransactionsController#index.
 *
 * Port of app/views/admin/transactions/index.html.erb, markup and classes as
 * they were, in the public_dashboard layout. It used to reuse the dashboard's
 * React tab, which dropped the Back to Home / Integration Settings buttons and
 * changed the table.
 */

import { ListHeader, ListPagination } from "@/components/dashboard/rails-list-parts";
import { CompanyNotFound } from "@/components/dashboard/not-found-notice";
import { PublicDashboardLayout } from "@/components/layouts/rails-layouts";
import { humanize, railsDate, railsTime } from "@/lib/dashboard/rails-format";
import { loadTransactions } from "@/lib/dashboard/screens";
import { firstValue, type RawSearchParams } from "@/lib/dashboard/searchparams";

export const dynamic = "force-dynamic";

const BADGE = "inline-flex items-center px-2 py-1 text-xs font-medium rounded";

export default async function TransactionsPage({
  searchParams,
}: {
  searchParams: Promise<RawSearchParams>;
}) {
  const params = await searchParams;
  const dri = firstValue(params, "dri");
  const data = await loadTransactions(dri, firstValue(params, "page"));
  if (!data || !dri) return <CompanyNotFound />;

  return (
    <PublicDashboardLayout>
      <ListHeader
        title="Customer Type Transactions"
        companyName={data.companyName}
        dri={dri}
      />

      {/* Stats Cards */}
      <div className="grid grid-cols-2 gap-4 mb-6">
        <div className="rounded-lg p-4 border border-green-200 bg-green-50">
          <div className="text-sm text-green-700 mb-1">Total Preferred</div>
          <div className="text-2xl font-bold text-green-900">
            {data.stats.total_preferred}
          </div>
          <div className="text-xs text-green-600 mt-1">upgrades</div>
        </div>

        <div className="rounded-lg p-4 border border-orange-200 bg-orange-50">
          <div className="text-sm text-orange-700 mb-1">Total Retail</div>
          <div className="text-2xl font-bold text-orange-900">
            {data.stats.total_retail}
          </div>
          <div className="text-xs text-orange-600 mt-1">downgrades</div>
        </div>
      </div>

      {/* Transactions Table */}
      <div className="bg-white rounded-lg border border-gray-100">
        <table className="w-full">
          <thead className="bg-slate-50 border-b border-gray-400">
            <tr>
              <th className="pl-4 py-3 text-left text-slate-600">Date/Time</th>
              <th className="px-4 py-3 text-left text-slate-600">Customer ID</th>
              <th className="px-4 py-3 text-left text-slate-600">External ID</th>
              <th className="px-4 py-3 text-left text-slate-600">Previous Type</th>
              <th className="px-4 py-3 text-left text-slate-600">New Type</th>
              <th className="px-4 py-3 text-left text-slate-600">Source</th>
              <th className="pr-4 py-3 text-left text-slate-600">Status</th>
            </tr>
          </thead>
          <tbody>
            {data.transactions.length === 0 ? (
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
                      d="M9 12h6m-6 4h6m2 5H7a2 2 0 01-2-2V5a2 2 0 012-2h5.586a1 1 0 01.707.293l5.414 5.414a1 1 0 01.293.707V19a2 2 0 01-2 2z"
                    />
                  </svg>
                  <p className="font-medium">No transactions yet</p>
                  <p className="text-sm mt-1 mb-6">
                    Customer type changes will appear here
                  </p>
                </td>
              </tr>
            ) : (
              data.transactions.map((t) => (
                <tr
                  key={t.id}
                  className="odd:bg-white even:bg-slate-50 hover:bg-slate-100 border-b border-gray-100"
                >
                  <td className="pl-4 py-3 text-gray-700 text-sm">
                    {railsDate(t.created_at)}
                    <span className="text-gray-400 block text-xs">
                      {railsTime(t.created_at)}
                    </span>
                  </td>
                  <td className="px-4 py-3 text-gray-700 font-mono text-sm">
                    {t.customer_id ?? "-"}
                  </td>
                  <td className="px-4 py-3 text-gray-700 font-mono text-sm">
                    {t.external_id ?? "-"}
                  </td>
                  <td className="px-4 py-3">
                    {t.previous_type ? (
                      <span className={`${BADGE} bg-gray-100 text-gray-700`}>
                        {humanize(t.previous_type)}
                      </span>
                    ) : (
                      <span className="text-gray-400 text-sm">-</span>
                    )}
                  </td>
                  <td className="px-4 py-3">
                    {t.new_type === "preferred_customer" ? (
                      <span className={`${BADGE} bg-green-100 text-green-800`}>
                        Preferred
                      </span>
                    ) : t.new_type === "retail" ? (
                      <span className={`${BADGE} bg-orange-100 text-orange-800`}>
                        Retail
                      </span>
                    ) : (
                      <span className={`${BADGE} bg-gray-100 text-gray-700`}>
                        {t.new_type}
                      </span>
                    )}
                  </td>
                  <td className="px-4 py-3">
                    <span className={`${BADGE} bg-blue-50 text-blue-700`}>
                      {humanize(t.source)}
                    </span>
                  </td>
                  <td className="pr-4 py-3">
                    {t.upgraded ? (
                      <span className="inline-flex items-center text-green-600 text-sm">
                        <svg
                          className="w-4 h-4 mr-1"
                          fill="none"
                          stroke="currentColor"
                          viewBox="0 0 24 24"
                          aria-hidden="true"
                        >
                          <path
                            strokeLinecap="round"
                            strokeLinejoin="round"
                            strokeWidth={2}
                            d="M5 10l7-7m0 0l7 7m-7-7v18"
                          />
                        </svg>
                        Upgraded
                      </span>
                    ) : t.downgraded ? (
                      <span className="inline-flex items-center text-orange-600 text-sm">
                        <svg
                          className="w-4 h-4 mr-1"
                          fill="none"
                          stroke="currentColor"
                          viewBox="0 0 24 24"
                          aria-hidden="true"
                        >
                          <path
                            strokeLinecap="round"
                            strokeLinejoin="round"
                            strokeWidth={2}
                            d="M19 14l-7 7m0 0l-7-7m7 7V3"
                          />
                        </svg>
                        Downgraded
                      </span>
                    ) : (
                      <span className="text-gray-500 text-sm">Changed</span>
                    )}
                  </td>
                </tr>
              ))
            )}
          </tbody>
        </table>

        <ListPagination
          path="/admin/transactions"
          dri={dri}
          page={data.page}
          perPage={data.perPage}
          shown={data.transactions.length}
          totalCount={data.totalCount}
          totalPages={data.totalPages}
          noun="transactions"
        />
      </div>
    </PublicDashboardLayout>
  );
}
