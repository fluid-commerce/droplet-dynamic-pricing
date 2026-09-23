/**
 * The shapes the dashboard's client components render.
 *
 * Lived in `app/frontend/entrypoints/dashboard.tsx` under Vite, where the
 * entrypoint was both the mount and the type home. Under the App Router the
 * server page needs them too, and a server component cannot import from a
 * `"use client"` module without dragging it into the server graph — so they
 * move here, where both sides can reach them.
 */

export type TabValue = "cart_events" | "transactions";

export interface Stats {
  total_preferred: number;
  total_retail: number;
  preferred_pricing_applied: number;
  total_cart_events: number;
}

export interface CartEvent {
  /** String, not number: the Rails id is a bigint and does not survive JSON. */
  id: string;
  cart_id: number | null;
  email_safe: string | null;
  event_type: string | null;
  items_count: number | null;
  cart_total: string | null;
  preferred_pricing_applied: boolean;
  created_at: string;
}

export interface Transaction {
  id: string;
  customer_id: number | null;
  external_id: string | null;
  previous_type: string | null;
  new_type: string | null;
  source: string | null;
  upgraded: boolean;
  downgraded: boolean;
  created_at: string;
}
