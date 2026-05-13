import React from "react"
import { createRoot } from "react-dom/client"
import { MoreVertical, Settings } from "lucide-react"

import { CartEventsTab } from "~/components/dashboard/CartEventsTab"
import { TransactionsTab } from "~/components/dashboard/TransactionsTab"
import { Button } from "~/components/ui/button"
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "~/components/ui/dropdown-menu"
import { Tabs, TabsContent, TabsList, TabsTrigger } from "~/components/ui/tabs"

export interface Stats {
  total_preferred: number
  total_retail: number
  preferred_pricing_applied: number
  total_cart_events: number
}

export interface CartEvent {
  id: number
  cart_id: number | null
  email_safe: string | null
  event_type: string
  items_count: number | null
  cart_total: string | null
  preferred_pricing_applied: boolean
  created_at: string
}

export interface Transaction {
  id: number
  customer_id: number | null
  external_id: string | null
  previous_type: string | null
  new_type: string
  source: string
  upgraded: boolean
  downgraded: boolean
  created_at: string
}

type TabValue = "cart_events" | "transactions"

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
    perPage: Number(ds.perPage ?? 10) || 10,
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
    <div className="space-y-8">
      <div className="flex items-start justify-between gap-4">
        <div className="flex flex-col gap-1">
          <h1 className="text-3xl font-bold tracking-tight text-foreground">
            Dynamic Pricing Dashboard
          </h1>
          <p className="text-sm text-muted-foreground">{data.companyName}</p>
        </div>
        <DropdownMenu>
          <DropdownMenuTrigger asChild>
            <Button variant="ghost" size="icon" aria-label="Open menu">
              <MoreVertical />
            </Button>
          </DropdownMenuTrigger>
          <DropdownMenuContent align="end">
            <DropdownMenuItem
              onSelect={() => window.location.assign(data.integrationSettingsUrl)}
            >
              <Settings className="mr-2 h-4 w-4" />
              Integration Settings
            </DropdownMenuItem>
          </DropdownMenuContent>
        </DropdownMenu>
      </div>

      <Tabs value={data.activeTab} onValueChange={handleTabChange} className="space-y-6">
        <TabsList className="h-10 p-1">
          <TabsTrigger value="cart_events" className="px-4">
            Cart Events
          </TabsTrigger>
          <TabsTrigger value="transactions" className="px-4">
            Customer Type Transactions
          </TabsTrigger>
        </TabsList>

        <TabsContent value="cart_events" className="mt-0">
          <CartEventsTab
            events={data.cartEvents}
            preferredAppliedCount={data.stats.preferred_pricing_applied}
            totalCount={data.cartTotalCount}
            page={data.activeTab === "cart_events" ? data.page : 1}
            perPage={data.perPage}
            hrefForPage={cartHrefForPage}
          />
        </TabsContent>

        <TabsContent value="transactions" className="mt-0">
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
