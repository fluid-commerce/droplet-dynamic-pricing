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

export type TabValue = "cart_events" | "transactions"
