/**
 * The dropzone dashboard's data layer.
 *
 * Port of DynamicPricingDashboardController (app/controllers/
 * dynamic_pricing_dashboard_controller.rb) and the payload the ERB built for
 * `dashboard.tsx`.
 *
 * TENANCY NOTE. The company is selected by the `dri` query parameter and
 * nothing else, exactly as Rails did — `ApplicationController#set_dri` is
 * `@dri = params[:dri]`, unsigned. That is preserved here because it is the
 * embed contract: Fluid's dropzone appends only `public_id` to the configured
 * URL, so the `dri` has to be baked into `embed_url` by the droplet admin, and
 * changing the scheme means changing what Fluid stores for four live merchants.
 *
 * It is preserved, NOT endorsed. Anyone who learns a `dri` reads that company's
 * cart pricing events and customer type transactions. See PARITY-AUDIT.md §3.
 * What this port does NOT carry across is the credential leak that sat behind
 * the same parameter — see `src/app/admin/integration-settings`.
 */

import { prisma } from "@/lib/db";

export type TabValue = "cart_events" | "transactions";

const ALLOWED_TABS: readonly TabValue[] = ["cart_events", "transactions"];
export const PER_PAGE = 10;

/**
 * `CartPricingEvent#email_safe`: `email.gsub(/(?<=.{2}).(?=.*@)/, "*")`.
 *
 * Keeps the first two characters of the local part and masks every character
 * after them up to — but not including — the `@`. A local part of two or fewer
 * characters is left alone, because no character satisfies the lookbehind.
 */
export function maskEmail(email: string | null | undefined): string | null {
  if (!email || email.trim() === "") return null;

  // JS supports lookbehind in every runtime this app targets (Node 18+), so
  // the Ruby regex ports literally rather than being reimplemented by hand.
  return email.replace(/(?<=.{2})./g, (char, offset: number) =>
    email.slice(offset + 1).includes("@") ? "*" : char,
  );
}

/** ALLOWED_TABS, with the same fallback. */
export function resolveTab(tab: string | undefined): TabValue {
  return ALLOWED_TABS.includes(tab as TabValue)
    ? (tab as TabValue)
    : "cart_events";
}

/** `[(params[:page] || 1).to_i, 1].max` — including `to_i`'s 0 for garbage. */
export function resolvePage(page: string | undefined): number {
  const parsed = Number.parseInt(page ?? "1", 10);
  if (!Number.isFinite(parsed)) return 1;
  return Math.max(parsed, 1);
}

export interface PageWindow {
  cartEvents: { take: number; skip: number };
  transactions: { take: number; skip: number };
}

/**
 * Only the ACTIVE tab is offset.
 *
 * Both lists are rendered on every request, but there is one `?page=`. Applying
 * it to both would scroll the hidden list too, so the inactive tab always shows
 * its first page — which is what Rails did, and what makes switching tabs land
 * on page 1 rather than on wherever the other tab happened to be.
 */
export function pageWindow(
  activeTab: TabValue,
  page: number,
  perPage: number,
): PageWindow {
  const offset = (page - 1) * perPage;

  return {
    cartEvents: {
      take: perPage,
      skip: activeTab === "cart_events" ? offset : 0,
    },
    transactions: {
      take: perPage,
      skip: activeTab === "transactions" ? offset : 0,
    },
  };
}

export interface DashboardStats {
  total_preferred: number;
  total_retail: number;
  preferred_pricing_applied: number;
  total_cart_events: number;
}

export interface DashboardPayload {
  companyName: string;
  activeTab: TabValue;
  page: number;
  perPage: number;
  stats: DashboardStats;
  cartEvents: Array<{
    id: string;
    cart_id: number | null;
    email_safe: string | null;
    event_type: string | null;
    items_count: number | null;
    cart_total: string | null;
    preferred_pricing_applied: boolean;
    created_at: string;
  }>;
  cartTotalCount: number;
  transactions: Array<{
    id: string;
    customer_id: number | null;
    external_id: string | null;
    previous_type: string | null;
    new_type: string | null;
    source: string | null;
    upgraded: boolean;
    downgraded: boolean;
    created_at: string;
  }>;
  txTotalCount: number;
}

/** null means no company matched the `dri` — Rails answered 404 "Company not found". */
export async function loadDashboard(
  dri: string | undefined,
  tab: string | undefined,
  page: string | undefined,
): Promise<DashboardPayload | null> {
  if (!dri) return null;

  // findFirst, not findUnique: droplet_installation_uuid carries no unique
  // index in Rails, and a company that reinstalls gets a second row.
  const company = await prisma.company.findFirst({
    // `active` also disambiguates the reinstall case above: the stale row is
    // the one uninstall marked false.
    where: { dropletInstallationUuid: dri, active: { not: false } },
  });
  if (!company) return null;

  const activeTab = resolveTab(tab);
  const currentPage = resolvePage(page);
  const windows = pageWindow(activeTab, currentPage, PER_PAGE);

  const [events, transactions, cartTotalCount, txTotalCount, stats] =
    await Promise.all([
      prisma.cartPricingEvent.findMany({
        where: { companyId: company.id },
        orderBy: { createdAt: "desc" },
        ...windows.cartEvents,
      }),
      prisma.customerTypeTransaction.findMany({
        where: { companyId: company.id },
        orderBy: { createdAt: "desc" },
        ...windows.transactions,
      }),
      prisma.cartPricingEvent.count({ where: { companyId: company.id } }),
      prisma.customerTypeTransaction.count({
        where: { companyId: company.id },
      }),
      loadStats(company.id),
    ]);

  return {
    companyName: company.name ?? "",
    activeTab,
    page: currentPage,
    perPage: PER_PAGE,
    stats,
    // BigInt ids never reach a client component — they do not survive JSON.
    cartEvents: events.map((event) => ({
      id: String(event.id),
      cart_id: event.cartId,
      email_safe: maskEmail(event.email),
      event_type: event.eventType,
      items_count: event.itemsCount,
      cart_total: event.cartTotal === null ? null : String(event.cartTotal),
      preferred_pricing_applied: event.preferredPricingApplied ?? false,
      created_at: event.createdAt.toISOString(),
    })),
    cartTotalCount,
    transactions: transactions.map((tx) => ({
      id: String(tx.id),
      customer_id: tx.customerId,
      external_id: tx.externalId,
      previous_type: tx.previousType,
      new_type: tx.newType,
      source: tx.source,
      upgraded: tx.newType === "preferred_customer",
      downgraded: tx.newType === "retail",
      created_at: tx.createdAt.toISOString(),
    })),
    txTotalCount,
  };
}

async function loadStats(companyId: bigint): Promise<DashboardStats> {
  const [totalPreferred, totalRetail, preferredApplied, totalCartEvents] =
    await Promise.all([
      prisma.customerTypeTransaction.count({
        where: { companyId, newType: "preferred_customer" },
      }),
      prisma.customerTypeTransaction.count({
        where: { companyId, newType: "retail" },
      }),
      prisma.cartPricingEvent.count({
        where: { companyId, preferredPricingApplied: true },
      }),
      prisma.cartPricingEvent.count({ where: { companyId } }),
    ]);

  return {
    total_preferred: totalPreferred,
    total_retail: totalRetail,
    preferred_pricing_applied: preferredApplied,
    total_cart_events: totalCartEvents,
  };
}
