import React from "react"
import { createRoot } from "react-dom/client"

import { CartEventsTab } from "~/components/dashboard/CartEventsTab"
import { KebabMenu } from "~/components/dashboard/KebabMenu"
import { TransactionsTab } from "~/components/dashboard/TransactionsTab"
import type {
  CartEvent,
  Stats,
  TabValue,
  Transaction,
} from "~/components/dashboard/types"
import { Tabs, TabsContent, TabsList, TabsTrigger } from "~/components/ui/tabs"

interface DashboardData {
  companyName: string
  activeTab: TabValue
  page: number
  perPage: number
  stats: Stats
  cartEvents: CartEvent[]
  cartTotalCount: number
  transactions: Transaction[]
  txTotalCount: number
  integrationSettingsUrl: string
  baseUrl: string
}

function readData(el: HTMLElement): DashboardData {
  const ds = el.dataset
  const activeTab: TabValue =
    ds.activeTab === "transactions" ? "transactions" : "cart_events"
  return {
    companyName: ds.companyName ?? "",
    activeTab,
    page: Number(ds.page ?? 1) || 1,
    perPage: Number(ds.perPage ?? 50) || 50,
    stats: JSON.parse(ds.stats ?? "{}") as Stats,
    cartEvents: JSON.parse(ds.cartEvents ?? "[]") as CartEvent[],
    cartTotalCount: Number(ds.cartTotalCount ?? 0) || 0,
    transactions: JSON.parse(ds.transactions ?? "[]") as Transaction[],
    txTotalCount: Number(ds.txTotalCount ?? 0) || 0,
    integrationSettingsUrl: ds.integrationSettingsUrl ?? "#",
    baseUrl: ds.baseUrl ?? "",
  }
}

function buildUrl(baseUrl: string, params: Record<string, string | number>) {
  const u = new URL(baseUrl, window.location.origin)
  for (const [k, v] of Object.entries(params)) {
    u.searchParams.set(k, String(v))
  }
  return u.pathname + u.search
}

function Dashboard({ data }: { data: DashboardData }) {
  const handleTabChange = (value: string) => {
    if (value !== data.activeTab) {
      window.location.assign(buildUrl(data.baseUrl, { tab: value, page: 1 }))
    }
  }

  const cartHrefForPage = (p: number) =>
    buildUrl(data.baseUrl, { tab: "cart_events", page: p })
  const txHrefForPage = (p: number) =>
    buildUrl(data.baseUrl, { tab: "transactions", page: p })

  return (
    <div className="space-y-6">
      <div className="flex items-start justify-between gap-4">
        <div className="flex flex-col gap-1">
          <h1 className="text-3xl font-bold text-foreground">
            Dynamic Pricing Dashboard
          </h1>
          <h3 className="text-muted-foreground">{data.companyName}</h3>
        </div>
        <KebabMenu integrationSettingsUrl={data.integrationSettingsUrl} />
      </div>

      <Tabs value={data.activeTab} onValueChange={handleTabChange}>
        <TabsList>
          <TabsTrigger value="cart_events">Cart Events</TabsTrigger>
          <TabsTrigger value="transactions">Customer Type Transactions</TabsTrigger>
        </TabsList>

        <TabsContent value="cart_events">
          <CartEventsTab
            events={data.cartEvents}
            preferredAppliedCount={data.stats.preferred_pricing_applied}
            totalCount={data.cartTotalCount}
            page={data.activeTab === "cart_events" ? data.page : 1}
            perPage={data.perPage}
            hrefForPage={cartHrefForPage}
          />
        </TabsContent>

        <TabsContent value="transactions">
          <TransactionsTab
            transactions={data.transactions}
            totalPreferred={data.stats.total_preferred}
            totalRetail={data.stats.total_retail}
            totalCount={data.txTotalCount}
            page={data.activeTab === "transactions" ? data.page : 1}
            perPage={data.perPage}
            hrefForPage={txHrefForPage}
          />
        </TabsContent>
      </Tabs>
    </div>
  )
}

const rootEl = document.getElementById("dashboard-root")
if (rootEl) {
  const data = readData(rootEl)
  createRoot(rootEl).render(
    <React.StrictMode>
      <Dashboard data={data} />
    </React.StrictMode>
  )
}
