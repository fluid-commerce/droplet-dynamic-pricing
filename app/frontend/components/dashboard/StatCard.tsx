import * as React from "react"

import { Card, CardContent } from "~/components/ui/card"

interface StatCardProps {
  label: string
  value: number | string
  hint?: string
}

export function StatCard({ label, value, hint }: StatCardProps) {
  return (
    <Card className="border-border/60 bg-muted/40">
      <CardContent className="p-5">
        <p className="text-sm font-medium text-muted-foreground">{label}</p>
        <p className="mt-2 text-3xl font-bold leading-none text-foreground">
          {value}
        </p>
        {hint && <p className="mt-2 text-xs text-muted-foreground">{hint}</p>}
      </CardContent>
    </Card>
  )
}
