/**
 * Resolving credentials from an install payload, v1 and v2.
 *
 * The droplet this port came from only ever saw v1, where the tokens arrive in
 * the payload. Fluid registers new droplets on v2, which sends a SHORT-LIVED
 * exchange token that has to be traded for the real ones. Droplet 165 is still
 * v1; the service this migration stands up will be v2, so both have to work.
 *
 * Found the hard way: a real install against a newly registered droplet failed
 * with "expected string, received undefined" at `company.authentication_token`,
 * and the company row was never written.
 */

import { describe, it, expect, vi, beforeEach } from "vitest";

import { resolveInstallCredentials } from "./install-credentials";

beforeEach(() => vi.clearAllMocks());

describe("v1 — tokens arrive in the payload", () => {
  it("reads them directly and never calls the exchange endpoint", async () => {
    const exchange = vi.fn();

    const result = await resolveInstallCredentials(
      {
        droplet_uuid: "drp_1",
        droplet_installation_uuid: "dri_1",
        fluid_company_id: 42,
        fluid_shop: "acme.fluid.app",
        name: "Acme",
        authentication_token: "dit_real",
        webhook_verification_token: "wvt_real",
      },
      exchange,
    );

    expect(result).toEqual({
      authenticationToken: "dit_real",
      webhookVerificationToken: "wvt_real",
    });
    expect(exchange).not.toHaveBeenCalled();
  });

  it("accepts a v1 payload with no webhook token", async () => {
    const result = await resolveInstallCredentials(
      {
        droplet_uuid: "drp_1",
        fluid_company_id: 42,
        fluid_shop: "acme.fluid.app",
        name: "Acme",
        authentication_token: "dit_real",
      },
      vi.fn(),
    );

    expect(result.webhookVerificationToken).toBeNull();
  });
});

describe("v2 — a short-lived token that has to be exchanged", () => {
  const v2 = {
    droplet_uuid: "drp_1",
    droplet_installation_uuid: "dri_1",
    fluid_company_id: 42,
    fluid_shop: "acme.fluid.app",
    name: "Acme",
    credentials: {
      exchange_token: "ext_short_lived",
      exchange_token_expires_at: "2026-09-17T13:00:00Z",
      exchange_endpoint: "/api/droplet_installations/exchange",
    },
  };

  it("trades the token and returns what came back", async () => {
    const exchange = vi.fn(async () => ({
      credentials: {
        authentication_token: "dit_exchanged",
        webhook_verification_token: "wvt_exchanged",
      },
    }));

    const result = await resolveInstallCredentials(v2, exchange);

    expect(exchange).toHaveBeenCalledWith(
      "ext_short_lived",
      "/api/droplet_installations/exchange",
    );
    expect(result).toEqual({
      authenticationToken: "dit_exchanged",
      webhookVerificationToken: "wvt_exchanged",
    });
  });

  it("propagates an exchange failure rather than writing a tokenless company", async () => {
    // A company row with no authentication_token is worse than no row: every
    // later Fluid call for that tenant 401s, and the install looks like it
    // worked.
    const exchange = vi.fn(async () => {
      throw new Error("Token exchange failed: 401 Unauthorized");
    });

    await expect(resolveInstallCredentials(v2, exchange)).rejects.toThrow(
      "Token exchange failed",
    );
  });

  it("refuses a response that carries no authentication token", async () => {
    const exchange = vi.fn(async () => ({ credentials: {} }) as never);

    await expect(resolveInstallCredentials(v2, exchange)).rejects.toThrow(
      /authentication_token/,
    );
  });
});
