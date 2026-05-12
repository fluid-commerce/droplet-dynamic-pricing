import * as React from "react"
import { ShoppingCart } from "lucide-react"

import { Pagination } from "./Pagination"
import { StatCard } from "./StatCard"
import type { CartEvent } from "./types"
import { Badge } from "~/components/ui/badge"

interface CartEventsTabProps {
  events: CartEvent[]
  preferredAppliedCount: number
  totalCount: number
  page: number
  perPage: number
  hrefForPage: (page: number) => string
}

const EVENT_TYPE_LABELS: Record<string, string> = {
  cart_created: "Cart Created",
  item_added: "Item Added",
  item_updated: "Item Updated",
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

function formatTotal(value: string | null) {
  if (value === null || value === "") return "-"
  const num = parseFloat(value)
  if (Number.isNaN(num)) return "-"
  return `$${num.toFixed(2)}`
}

export function CartEventsTab({
  events,
  preferredAppliedCount,
  totalCount,
  page,
  perPage,
  hrefForPage,
}: CartEventsTabProps) {
  return (
    <div className="space-y-6">
      <div className="grid grid-cols-1 gap-4 md:grid-cols-2">
        <StatCard
          label="Preferred Applied"
          value={preferredAppliedCount}
          hint="carts with preferred pricing"
        />
        <StatCard
          label="Total Events"
          value={totalCount}
          hint="all time"
        />
      </div>

      <div>
        <table className="w-full">
          <thead className="border-b">
            <tr>
              <th className="pl-6 py-4 text-left text-sm font-semibold text-foreground">Date/Time</th>
              <th className="px-4 py-4 text-left text-sm font-semibold text-foreground">Cart ID</th>
              <th className="px-4 py-4 text-left text-sm font-semibold text-foreground">Email</th>
              <th className="px-4 py-4 text-left text-sm font-semibold text-foreground">Event Type</th>
              <th className="px-4 py-4 text-left text-sm font-semibold text-foreground">Items</th>
              <th className="px-4 py-4 text-left text-sm font-semibold text-foreground">Cart Total</th>
              <th className="pr-6 py-4 text-left text-sm font-semibold text-foreground">Status</th>
            </tr>
          </thead>
          <tbody>
            {events.length === 0 ? (
              <tr>
                <td colSpan={7} className="text-center py-16 text-muted-foreground">
                  <ShoppingCart className="mb-3 mx-auto h-10 w-10 opacity-30" />
                  <p className="font-medium">No cart pricing events yet</p>
                  <p className="text-sm mt-1">
                    Cart pricing events will appear here when customers interact with carts
                  </p>
                </td>
              </tr>
            ) : (
              events.map((event) => {
                const { date, time } = formatDate(event.created_at)
                return (
                  <tr key={event.id} className="even:bg-muted/60">
                    <td className="pl-6 py-4 text-sm">
                      <div className="font-medium text-foreground">{date}</div>
                      <div className="text-muted-foreground text-xs">{time}</div>
                    </td>
                    <td className="px-4 py-4 font-mono text-sm">{event.cart_id ?? "-"}</td>
                    <td className="px-4 py-4 text-sm text-muted-foreground">
                      {event.email_safe ?? "-"}
                    </td>
                    <td className="px-4 py-4">
                      <Badge variant="muted">
                        {EVENT_TYPE_LABELS[event.event_type] ?? event.event_type}
                      </Badge>
                    </td>
                    <td className="px-4 py-4 text-sm">{event.items_count ?? 0}</td>
                    <td className="px-4 py-4 text-sm font-medium">
                      {formatTotal(event.cart_total)}
                    </td>
                    <td className="pr-6 py-4">
                      <span className="text-foreground text-sm">
                        {event.preferred_pricing_applied
                          ? "Preferred Applied"
                          : "Removed Pricing"}
                      </span>
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
          shownCount={events.length}
          hrefForPage={hrefForPage}
          itemLabel="events"
        />
      </div>
    </div>
  )
}
