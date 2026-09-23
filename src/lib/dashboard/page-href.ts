/**
 * Paging links that survive the server/client boundary.
 *
 * The tab components are `"use client"`. A `hrefForPage: (page) => string` prop
 * works when the caller is itself a client component — `dashboard.tsx` builds
 * the closure on the client, so it never crosses a boundary. It does NOT work
 * from `/admin/transactions` or `/admin/cart_pricing_events`, which are server
 * components: React refuses to serialize a function, and both pages answered
 * 500 with "Functions cannot be passed directly to Client Components".
 *
 * A string template crosses either way, so all three callers pass the same
 * thing and the failure cannot come back for a fourth.
 */

/**
 * Survives `URLSearchParams` unchanged — no percent-encoding, so a template
 * built through the URL API still contains it verbatim when it reaches the
 * client. A placeholder like `{page}` does not: braces are encoded.
 */
export const PAGE_PLACEHOLDER = "__PAGE__";

export function pageHref(template: string, page: number): string {
  return template.split(PAGE_PLACEHOLDER).join(String(page));
}
