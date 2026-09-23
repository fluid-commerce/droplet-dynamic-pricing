"use client";

/**
 * The dropzone dashboard shell.
 *
 * Port of the `Dashboard` component in app/frontend/entrypoints/dashboard.tsx.
 * The markup and the tab/pagination behaviour are unchanged; what is gone is
 * the Vite mount — the data arrives as props from the server component instead
 * of through `data-*` attributes read at runtime.
 */

import { MoreVertical, Settings } from "lucide-react";

import { CartEventsTab } from "@/components/dashboard/CartEventsTab";
import { TransactionsTab } from "@/components/dashboard/TransactionsTab";
import { Button } from "@/components/ui/button";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { PAGE_PLACEHOLDER } from "@/lib/dashboard/page-href";
import type { DashboardPayload } from "@/lib/dashboard/query";

export interface DashboardProps extends DashboardPayload {
  /** Carried on every link so the iframe keeps its tenant across navigations. */
  dri: string;
}

function buildUrl(
  dri: string,
  params: Record<string, string | number>,
): string {
  const query = new URLSearchParams({ dri });
  for (const [key, value] of Object.entries(params)) {
    query.set(key, String(value));
  }
  return `/?${query}`;
}

export function Dashboard(data: DashboardProps) {
  const { dri } = data;

  const handleTabChange = (value: string) => {
    if (value !== data.activeTab) {
      // A full navigation, as under Vite. The page is server-rendered per tab,
      // so the new tab's rows come from the server rather than being paged in
      // the browser from a payload that was never sent.
      window.location.assign(buildUrl(dri, { tab: value, page: 1 }));
    }
  };

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
              onSelect={() =>
                window.location.assign(
                  `/admin/integration_setting?${new URLSearchParams({ dri })}`,
                )
              }
            >
              <Settings className="mr-2 h-4 w-4" />
              Integration Settings
            </DropdownMenuItem>
          </DropdownMenuContent>
        </DropdownMenu>
      </div>

      <Tabs
        value={data.activeTab}
        onValueChange={handleTabChange}
        className="space-y-6"
      >
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
            pageHrefTemplate={buildUrl(dri, {
              tab: "cart_events",
              page: PAGE_PLACEHOLDER,
            })}
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
            pageHrefTemplate={buildUrl(dri, {
              tab: "transactions",
              page: PAGE_PLACEHOLDER,
            })}
          />
        </TabsContent>
      </Tabs>
    </div>
  );
}
