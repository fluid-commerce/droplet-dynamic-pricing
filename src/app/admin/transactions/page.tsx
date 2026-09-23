/**
 * GET /admin/transactions — Admin::TransactionsController#index.
 *
 * Underscored path kept, same reason as /admin/cart_pricing_events.
 */

import { CompanyNotFound } from "@/components/dashboard/not-found-notice";
import { TransactionsTab } from "@/components/dashboard/TransactionsTab";
import { loadTransactions } from "@/lib/dashboard/screens";
import { PAGE_PLACEHOLDER } from "@/lib/dashboard/page-href";
import { firstValue, type RawSearchParams } from "@/lib/dashboard/searchparams";

export const dynamic = "force-dynamic";

export default async function TransactionsPage({
  searchParams,
}: {
  searchParams: Promise<RawSearchParams>;
}) {
  const params = await searchParams;
  const dri = firstValue(params, "dri");
  const data = await loadTransactions(dri, firstValue(params, "page"));
  if (!data) return <CompanyNotFound />;

  return (
    <main className="mx-auto max-w-6xl p-6">
      <h1 className="text-3xl font-bold tracking-tight">
        Customer Type Transactions
      </h1>
      <p className="mt-1 mb-8 text-sm text-muted-foreground">
        {data.companyName}
      </p>

      <TransactionsTab
        transactions={data.transactions}
        totalPreferred={data.stats.total_preferred}
        totalRetail={data.stats.total_retail}
        totalCount={data.totalCount}
        page={data.page}
        perPage={data.perPage}
        pageHrefTemplate={`/admin/transactions?${new URLSearchParams({
          dri: dri ?? "",
          page: PAGE_PLACEHOLDER,
        })}`}
      />
    </main>
  );
}
