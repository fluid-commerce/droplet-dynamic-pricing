/**
 * Pins the ORIGINAL's behaviour, which is not the same as "every event has a
 * label".
 *
 * Three of the six enum values are labelled and three render raw. That looks
 * like a gap, and porting it faithfully was a deliberate choice: the merchants
 * using this droplet see `customer_logged_in` in that column today, and
 * changing what a live screen says belongs in its own change with someone
 * choosing the wording — not smuggled into a migration.
 *
 * If that decision gets made, this file is where it shows up: the second test
 * fails the moment the map grows.
 */

import { describe, it, expect } from "vitest";

import { EVENT_TYPE_LABELS, labelForEventType } from "./event-labels";

describe("labelForEventType", () => {
  it.each([
    ["cart_created", "Cart Created"],
    ["item_added", "Item Added"],
    ["item_updated", "Item Updated"],
  ])("labels %s", (eventType, label) => {
    expect(labelForEventType(eventType)).toBe(label);
  });

  it.each(["customer_logged_in", "customer_detached", "country_changed"])(
    "renders %s raw, as the original does",
    (eventType) => {
      expect(labelForEventType(eventType)).toBe(eventType);
    },
  );

  it("still has exactly the original's three entries", () => {
    // Fails if someone adds the missing labels. That is a screen change worth
    // making on purpose; this is the tripwire that makes it a decision.
    expect(Object.keys(EVENT_TYPE_LABELS).sort()).toEqual([
      "cart_created",
      "item_added",
      "item_updated",
    ]);
  });

  it("renders a dash for a null event type", () => {
    // The one divergence kept: the column is nullable and Rails' payload typed
    // it as non-null, so a null row would have rendered `undefined`. "-" is
    // what every other empty cell in the table shows.
    expect(labelForEventType(null)).toBe("-");
  });
});
