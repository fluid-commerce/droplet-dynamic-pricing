/**
 * Trades a v2 install's short-lived token for real credentials.
 *
 * Port of `exchangeInstallToken` in droplet-template. Unauthenticated by
 * design: the exchange token IS the credential, it is single-use, and it
 * expires in minutes.
 *
 * A 30s timeout because this runs inside the `droplet.installed` handler, and
 * a hung request there is a webhook that never answers — Fluid retries, and
 * each retry carries a token that the first attempt may already have spent.
 */

import type { ExchangeResponse } from "@/lib/handlers/install-credentials";

const DEFAULT_PATH = "/api/droplet_installations/exchange";
const TIMEOUT_MS = 30_000;

export async function exchangeInstallToken(
  exchangeToken: string,
  exchangeEndpoint?: string,
): Promise<ExchangeResponse> {
  const baseUrl = process.env.FLUID_API_URL || "https://api.fluid.app";
  const url = `${baseUrl}${exchangeEndpoint || DEFAULT_PATH}`;

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);

  try {
    const response = await fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ exchange_token: exchangeToken }),
      signal: controller.signal,
    });

    if (!response.ok) {
      // The body can carry the reason (expired, already used) and never the
      // token itself, so it is safe and useful to surface.
      const body = await response.text();
      throw new Error(
        `Token exchange failed: ${response.status} ${response.statusText} - ${body}`,
      );
    }

    return (await response.json()) as ExchangeResponse;
  } finally {
    clearTimeout(timer);
  }
}
