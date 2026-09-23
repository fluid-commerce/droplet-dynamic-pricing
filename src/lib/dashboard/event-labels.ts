/**
 * What a cart pricing event is called on screen.
 *
 * Three of the six `CartPricingEvent` enum values are listed, and the other
 * three — `customer_logged_in`, `customer_detached`, `country_changed` — fall
 * through to the raw column value. That is not an oversight in this port: it is
 * what `app/frontend/components/dashboard/CartEventsTab.tsx` does in the
 * standalone repo, and it is what the merchants looking at this screen see
 * today.
 *
 * Adding the missing three is a one-line change and a visible improvement, but
 * it is a change to the screen, not a port of it. Worth doing deliberately,
 * separately, with someone deciding the wording.
 */
export const EVENT_TYPE_LABELS: Record<string, string> = {
  cart_created: "Cart Created",
  item_added: "Item Added",
  item_updated: "Item Updated",
};

export function labelForEventType(
  eventType: string | null | undefined,
): string {
  // The column is nullable. Rails' payload typed it as non-null and would have
  // rendered `undefined`; "-" matches every other empty cell in the table.
  if (eventType === null || eventType === undefined) return "-";

  return EVENT_TYPE_LABELS[eventType] ?? eventType;
}
