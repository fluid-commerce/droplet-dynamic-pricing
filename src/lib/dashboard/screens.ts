/**
 * The three list/stat screens Rails served from PublicAdminController.
 *
 * Ports of Admin::HomeController, Admin::CartPricingEventsController and
 * Admin::TransactionsController. Same `dri` tenancy as the dashboard — see the
 * note in query.ts.
 */

import { prisma } from "@/lib/db";

import { maskEmail, resolvePage, type DashboardStats } from "./query";

/**
 * 50, where the dashboard embed uses 10.
 *
 * Two numbers in two controllers, both deliberate: the embed renders inside a
 * dropzone panel, these render as full pages.
 */
export const LIST_PER_PAGE = 50;

/** `(total.to_f / per_page).ceil`. */
export function totalPages(total: number, perPage: number): number {
  return Math.ceil(total / perPage);
}

/**
 * Rails did NOT clamp here — `@page = (params[:page] || 1).to_i`, with no
 * `.max(1)` — so `?page=0` computed `offset(-50)` and Postgres refused the
 * query outright. Prisma throws on a negative `skip`, so that input is a 500
 * either way; clamping is the only reading that is not a crash, and it matches
 * DynamicPricingDashboardController in the same app, which did clamp.
 */
export function listWindow(page: number): { take: number; skip: number } {
  return { take: LIST_PER_PAGE, skip: Math.max(page - 1, 0) * LIST_PER_PAGE };
}

async function companyFor(dri: string | undefined) {
  if (!dri) return null;
  // See require-dri.ts: a `dri` kept after uninstall must stop working.
  return prisma.company.findFirst({
    where: { dropletInstallationUuid: dri, active: { not: false } },
  });
}

export interface HomeScreen {
  companyName: string;
  stats: DashboardStats;
}

/** Admin::HomeController#index — the same four counters the dashboard shows. */
export async function loadHome(
  dri: string | undefined,
): Promise<HomeScreen | null> {
  const company = await companyFor(dri);
  if (!company) return null;

  const [totalPreferred, totalRetail, preferredApplied, totalCartEvents] =
    await Promise.all([
      prisma.customerTypeTransaction.count({
        where: { companyId: company.id, newType: "preferred_customer" },
      }),
      prisma.customerTypeTransaction.count({
        where: { companyId: company.id, newType: "retail" },
      }),
      prisma.cartPricingEvent.count({
        where: { companyId: company.id, preferredPricingApplied: true },
      }),
      prisma.cartPricingEvent.count({ where: { companyId: company.id } }),
    ]);

  return {
    companyName: company.name ?? "",
    stats: {
      total_preferred: totalPreferred,
      total_retail: totalRetail,
      preferred_pricing_applied: preferredApplied,
      total_cart_events: totalCartEvents,
    },
  };
}

export interface CartEventsScreen {
  companyName: string;
  page: number;
  perPage: number;
  totalCount: number;
  totalPages: number;
  stats: { preferred_applied_count: number; total_events: number };
  events: Array<{
    id: string;
    cart_id: number | null;
    email_safe: string | null;
    event_type: string | null;
    items_count: number | null;
    cart_total: string | null;
    preferred_pricing_applied: boolean;
    created_at: string;
  }>;
}

export async function loadCartPricingEvents(
  dri: string | undefined,
  page: string | undefined,
): Promise<CartEventsScreen | null> {
  const company = await companyFor(dri);
  if (!company) return null;

  const currentPage = resolvePage(page);
  const where = { companyId: company.id };

  const [events, totalCount, preferredApplied] = await Promise.all([
    prisma.cartPricingEvent.findMany({
      where,
      orderBy: { createdAt: "desc" },
      ...listWindow(currentPage),
    }),
    prisma.cartPricingEvent.count({ where }),
    prisma.cartPricingEvent.count({
      where: { ...where, preferredPricingApplied: true },
    }),
  ]);

  return {
    companyName: company.name ?? "",
    page: currentPage,
    perPage: LIST_PER_PAGE,
    totalCount,
    totalPages: totalPages(totalCount, LIST_PER_PAGE),
    stats: {
      preferred_applied_count: preferredApplied,
      total_events: totalCount,
    },
    events: events.map((event) => ({
      id: String(event.id),
      cart_id: event.cartId,
      email_safe: maskEmail(event.email),
      event_type: event.eventType,
      items_count: event.itemsCount,
      cart_total: event.cartTotal === null ? null : String(event.cartTotal),
      preferred_pricing_applied: event.preferredPricingApplied ?? false,
      created_at: event.createdAt.toISOString(),
    })),
  };
}

export interface TransactionsScreen {
  companyName: string;
  page: number;
  perPage: number;
  totalCount: number;
  totalPages: number;
  stats: { total_preferred: number; total_retail: number };
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
}

export async function loadTransactions(
  dri: string | undefined,
  page: string | undefined,
): Promise<TransactionsScreen | null> {
  const company = await companyFor(dri);
  if (!company) return null;

  const currentPage = resolvePage(page);
  const where = { companyId: company.id };

  const [transactions, totalCount, totalPreferred, totalRetail] =
    await Promise.all([
      prisma.customerTypeTransaction.findMany({
        where,
        orderBy: { createdAt: "desc" },
        ...listWindow(currentPage),
      }),
      prisma.customerTypeTransaction.count({ where }),
      prisma.customerTypeTransaction.count({
        where: { ...where, newType: "preferred_customer" },
      }),
      prisma.customerTypeTransaction.count({
        where: { ...where, newType: "retail" },
      }),
    ]);

  return {
    companyName: company.name ?? "",
    page: currentPage,
    perPage: LIST_PER_PAGE,
    totalCount,
    totalPages: totalPages(totalCount, LIST_PER_PAGE),
    stats: { total_preferred: totalPreferred, total_retail: totalRetail },
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
  };
}
