import * as React from "react"
import { ArrowDown, ArrowUp, FileText } from "lucide-react"

import { Pagination } from "./Pagination"
import { StatCard } from "./StatCard"
import type { Transaction } from "./types"
import { Badge } from "~/components/ui/badge"

interface TransactionsTabProps {
  transactions: Transaction[]
  totalPreferred: number
  totalRetail: number
  totalCount: number
  page: number
  perPage: number
  hrefForPage: (page: number) => string
}

function formatDate(iso: string) {
  const d = new Date(iso)
  const date = d.toLocaleDateString("en-US", {
    month: "short",
    day: "numeric",
    year: "numeric",
  })
  const time = d.toLocaleTimeString("en-US", {
    hour: "2-digit",
    minute: "2-digit",
    hour12: true,
  })
  return { date, time }
}

function humanize(value: string | null | undefined) {
  if (!value) return ""
  return value
    .replace(/_/g, " ")
    .replace(/\b\w/g, (c) => c.toUpperCase())
}

export function TransactionsTab({
  transactions,
  totalPreferred,
  totalRetail,
  totalCount,
  page,
  perPage,
  hrefForPage,
}: TransactionsTabProps) {
  return (
    <div className="space-y-6">
      <div className="grid grid-cols-1 gap-4 md:grid-cols-2">
        <StatCard
          label="Total Preferred"
          value={totalPreferred}
          hint="upgrades"
        />
        <StatCard
          label="Total Retail"
          value={totalRetail}
          hint="downgrades"
        />
      </div>

      <div>
        <table className="w-full">
          <thead className="border-b">
            <tr>
              <th className="pl-6 py-4 text-left text-sm font-semibold text-foreground">Date/Time</th>
              <th className="px-4 py-4 text-left text-sm font-semibold text-foreground">Customer ID</th>
              <th className="px-4 py-4 text-left text-sm font-semibold text-foreground">External ID</th>
              <th className="px-4 py-4 text-left text-sm font-semibold text-foreground">Previous Type</th>
              <th className="px-4 py-4 text-left text-sm font-semibold text-foreground">New Type</th>
              <th className="px-4 py-4 text-left text-sm font-semibold text-foreground">Source</th>
              <th className="pr-6 py-4 text-left text-sm font-semibold text-foreground">Status</th>
            </tr>
          </thead>
          <tbody>
            {transactions.length === 0 ? (
              <tr>
                <td colSpan={7} className="text-center py-16 text-muted-foreground">
                  <FileText className="mb-3 mx-auto h-10 w-10 opacity-30" />
                  <p className="font-medium">No transactions yet</p>
                  <p className="text-sm mt-1">Customer type changes will appear here</p>
                </td>
              </tr>
            ) : (
              transactions.map((tx) => {
                const { date, time } = formatDate(tx.created_at)
                const newTypeLabel =
                  tx.new_type === "preferred_customer"
                    ? "Preferred"
                    : tx.new_type === "retail"
                      ? "Retail"
                      : tx.new_type
                return (
                  <tr key={tx.id} className="even:bg-muted/60">
                    <td className="pl-6 py-4 text-sm">
                      <div className="font-medium text-foreground">{date}</div>
                      <div className="text-muted-foreground text-xs">{time}</div>
                    </td>
                    <td className="px-4 py-4 font-mono text-sm">{tx.customer_id ?? "-"}</td>
                    <td className="px-4 py-4 font-mono text-sm">{tx.external_id ?? "-"}</td>
                    <td className="px-4 py-4">
                      {tx.previous_type ? (
                        <Badge variant="muted">{humanize(tx.previous_type)}</Badge>
                      ) : (
                        <span className="text-muted-foreground text-sm">-</span>
                      )}
                    </td>
                    <td className="px-4 py-4">
                      <Badge variant="muted">{newTypeLabel}</Badge>
                    </td>
                    <td className="px-4 py-4">
                      <Badge variant="muted">{humanize(tx.source)}</Badge>
                    </td>
                    <td className="pr-6 py-4">
                      {tx.upgraded ? (
                        <span className="inline-flex items-center text-foreground text-sm">
                          <ArrowUp className="mr-1 size-4" />
                          Upgraded
                        </span>
                      ) : tx.downgraded ? (
                        <span className="inline-flex items-center text-foreground text-sm">
                          <ArrowDown className="mr-1 size-4" />
                          Downgraded
                        </span>
                      ) : (
                        <span className="text-foreground text-sm">Changed</span>
                      )}
                    </td>
                  </tr>
                )
              })
            )}
          </tbody>
        </table>

        <Pagination
          page={page}
          perPage={perPage}
          totalCount={totalCount}
          shownCount={transactions.length}
          hrefForPage={hrefForPage}
          itemLabel="transactions"
        />
      </div>
    </div>
  )
}
