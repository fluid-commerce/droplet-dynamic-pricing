/**
 * `servesCallbackUrl` — the guard that stops this droplet registering a URL it
 * cannot answer, and the one transitional case where it must NOT.
 *
 * The Rails original (`Callback.serves?`) exists because `CallbackSyncService`
 * imports every definition Fluid offers, so the admin list contains names this
 * droplet has no handler for. Enabling one registered a URL that 404s on every
 * dispatch — that is how TM3's `verify_email_success` registration came to
 * exist.
 */

import { describe, it, expect, vi, afterEach } from "vitest";

import { servesCallbackUrl } from "./registration";

const own = "next.example.run.app";
const rails = "rails.example.run.app";
const hosts = { own, rails };

describe("servesCallbackUrl", () => {
  it("accepts this app's own paths on this app's host", () => {
    expect(
      servesCallbackUrl(`https://${own}/api/callbacks/cart-item-added`, hosts),
    ).toBe(true);
    expect(
      servesCallbackUrl(
        `https://${own}/api/callbacks/cart-subscription-added`,
        hosts,
      ),
    ).toBe(true);
  });

  it("refuses a path this app does not route, on its own host", () => {
    // The `verify_email_success` shape: a real definition name, no handler.
    expect(
      servesCallbackUrl(`https://${own}/api/callbacks/verify-email-success`, hosts),
    ).toBe(false);
    expect(servesCallbackUrl(`https://${own}/api/webhooks`, hosts)).toBe(false);
  });

  it("refuses one of its own paths on somebody else's host", () => {
    // A stale or foreign host 404s in production no matter how valid the path
    // looks here.
    expect(
      servesCallbackUrl(
        "https://someone-else.example.com/api/callbacks/cart-item-added",
        hosts,
      ),
    ).toBe(false);
  });

  it("ACCEPTS a Rails path on the Rails host, which is the transitional case", () => {
    // Once droplet.installed points here but the callbacks table still holds
    // the Rails urls, a new installation is registered by THIS app from rows
    // describing the OTHER one. Refusing would register nothing at all and the
    // company would look installed while receiving no pricing callbacks.
    expect(
      servesCallbackUrl(`https://${rails}/callbacks/cart_item_added`, hosts),
    ).toBe(true);
    // Including the two whose Rails path is not their definition name.
    expect(
      servesCallbackUrl(`https://${rails}/callbacks/subscription_added`, hosts),
    ).toBe(true);
    expect(
      servesCallbackUrl(`https://${rails}/callbacks/customer_logged_in`, hosts),
    ).toBe(true);
  });

  it("refuses a Rails path on a host that is not the Rails app", () => {
    // The widening is scoped to the one host we can name from
    // Setting.host_server.base_url. Anything else is still a 404 waiting to
    // happen.
    expect(
      servesCallbackUrl(`https://${own}/callbacks/cart_item_added`, hosts),
    ).toBe(false);
    expect(
      servesCallbackUrl("https://evil.example.com/callbacks/cart_item_added", hosts),
    ).toBe(false);
  });

  it("refuses a Rails path when no Rails host is configured", () => {
    expect(
      servesCallbackUrl(`https://${rails}/callbacks/cart_item_added`, { own }),
    ).toBe(false);
  });

  it("refuses anything that is not an absolute http(s) url", () => {
    expect(servesCallbackUrl("/api/callbacks/cart-item-added", hosts)).toBe(false);
    expect(servesCallbackUrl("//host/api/callbacks/cart-item-added", hosts)).toBe(
      false,
    );
    expect(
      servesCallbackUrl("ftp://host/api/callbacks/cart-item-added", hosts),
    ).toBe(false);
    expect(servesCallbackUrl("", hosts)).toBe(false);
  });

  it("tolerates a trailing slash and surrounding whitespace", () => {
    // `Callback` normalises `url` with `.strip` in Rails, and an operator
    // pasting a url picks up both of these.
    expect(
      servesCallbackUrl(` https://${own}/api/callbacks/cart-item-added/ `, hosts),
    ).toBe(true);
  });
});

/**
 * The WIRING, not just the predicate.
 *
 * The tests above prove `servesCallbackUrl` accepts a Rails path on the Rails
 * host. They do not prove `activeCallbacks()` ever asks it the right question —
 * and that is where the new-install window actually closes. A broken
 * `hostServerBaseUrl()` lookup, or the hosts object being assembled wrongly,
 * would leave a fresh installation with zero callback registrations while every
 * assertion above stayed green.
 */
describe("activeCallbacks", () => {
  const rows = (url: string) => [
    { name: "cart_item_added", url, timeoutInSeconds: 20 },
  ];

  async function subject(
    url: string,
    { railsBaseUrl }: { railsBaseUrl?: string } = {},
  ) {
    vi.resetModules();
    process.env.FLUID_DROPLET_URL = "https://next.example.run.app";

    vi.doMock("@/lib/db", () => ({
      prisma: { callback: { findMany: vi.fn(async () => rows(url)) } },
    }));
    vi.doMock("@/lib/settings", () => ({
      hostServerBaseUrl: vi.fn(async () => {
        if (!railsBaseUrl) throw new Error("no host_server row");
        return railsBaseUrl;
      }),
    }));

    const { activeCallbacks } = await import("./registration");
    return activeCallbacks();
  }

  afterEach(() => {
    vi.doUnmock("@/lib/db");
    vi.doUnmock("@/lib/settings");
    vi.resetModules();
  });

  it("registers a row already pointing at this app", async () => {
    const active = await subject(
      "https://next.example.run.app/api/callbacks/cart-item-added",
    );
    expect(active.map((c) => c.name)).toEqual(["cart_item_added"]);
  });

  it("registers a row still pointing at RAILS, closing the new-install window", async () => {
    const active = await subject(
      "https://rails.example.run.app/callbacks/cart_item_added",
      { railsBaseUrl: "https://rails.example.run.app" },
    );
    expect(active.map((c) => c.name)).toEqual(["cart_item_added"]);
  });

  it("refuses a Rails-path row when host_server names a different host", async () => {
    const active = await subject(
      "https://somewhere-else.example.com/callbacks/cart_item_added",
      { railsBaseUrl: "https://rails.example.run.app" },
    );
    expect(active).toEqual([]);
  });

  it("refuses a Rails-path row when host_server cannot be read at all", async () => {
    // Fails CLOSED. Without a host to compare against, "a Rails path on the
    // Rails host" is not a question that can be answered, and registering a url
    // this app cannot vouch for is how the verify_email_success 404 loop began.
    const active = await subject(
      "https://rails.example.run.app/callbacks/cart_item_added",
    );
    expect(active).toEqual([]);
  });

  it("refuses a path neither app routes", async () => {
    const active = await subject(
      "https://next.example.run.app/api/callbacks/verify-email-success",
      { railsBaseUrl: "https://rails.example.run.app" },
    );
    expect(active).toEqual([]);
  });
});
