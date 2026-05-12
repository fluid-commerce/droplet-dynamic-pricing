import * as React from "react"
import { Button } from "~/components/ui/button"

interface PaginationProps {
  page: number
  perPage: number
  totalCount: number
  shownCount: number
  hrefForPage: (page: number) => string
  itemLabel: string
}

export function Pagination({
  page,
  perPage,
  totalCount,
  shownCount,
  hrefForPage,
  itemLabel,
}: PaginationProps) {
  const totalPages = Math.max(1, Math.ceil(totalCount / perPage))
  if (totalPages <= 1) return null

  const offset = (page - 1) * perPage
  const start = offset + 1
  const end = Math.min(offset + shownCount, totalCount)

  return (
    <div className="px-4 py-3 mt-4">
      <div className="flex items-center justify-between">
        <div className="text-sm text-muted-foreground">
          Showing {start}-{end} of {totalCount} {itemLabel}
        </div>
        <div className="flex gap-2">
          <Button
            variant="outline"
            size="sm"
            disabled={page <= 1}
            onClick={() => window.location.assign(hrefForPage(page - 1))}
          >
            Previous
          </Button>
          <Button
            variant="outline"
            size="sm"
            disabled={page >= totalPages}
            onClick={() => window.location.assign(hrefForPage(page + 1))}
          >
            Next
          </Button>
        </div>
      </div>
    </div>
  )
}
