/**
 * Credentials from an install payload, across both lifecycle contracts.
 *
 * v1 delivers `authentication_token` and `webhook_verification_token` in the
 * payload. v2 delivers a SHORT-LIVED `exchange_token` that has to be traded at
 * `exchange_endpoint` for the real pair.
 *
 * The droplet this port came from only ever saw v1 — droplet 165 is still v1 —
 * so the ported handler required the flat fields and threw on anything else.
 * Fluid registers NEW droplets on v2, which is every droplet this migration
 * stands up. A real install failed with "expected string, received undefined"
 * and no company row was written.
 *
 * Split out from the handler because the branch is worth testing on its own:
 * the v2 path spends a single-use token, and getting it wrong costs an install
 * that cannot simply be retried.
 */

import { z } from "zod";

export const v1CompanySchema = z.object({
  fluid_shop: z.string(),
  name: z.string(),
  fluid_company_id: z.union([z.number(), z.string()]),
  company_droplet_uuid: z.string().optional(),
  droplet_uuid: z.string(),
  droplet_installation_uuid: z.string().optional(),
  authentication_token: z.string(),
  webhook_verification_token: z.string().optional(),
});

export const v2CompanySchema = z.object({
  fluid_shop: z.string(),
  name: z.string(),
  fluid_company_id: z.union([z.number(), z.string()]),
  company_droplet_uuid: z.string().optional(),
  droplet_uuid: z.string(),
  droplet_installation_uuid: z.string().optional(),
  credentials: z.object({
    exchange_token: z.string(),
    exchange_token_expires_at: z.string().optional(),
    exchange_endpoint: z.string().optional(),
  }),
});

export const installCompanySchema = z.union([v1CompanySchema, v2CompanySchema]);
export const installPayloadSchema = z.object({ company: installCompanySchema });

export type InstallCompany = z.infer<typeof installCompanySchema>;

export interface ExchangeResponse {
  credentials?: {
    authentication_token?: string;
    webhook_verification_token?: string | null;
  };
}

export type TokenExchanger = (
  exchangeToken: string,
  exchangeEndpoint?: string,
) => Promise<ExchangeResponse>;

export interface ResolvedCredentials {
  authenticationToken: string;
  webhookVerificationToken: string | null;
}

export async function resolveInstallCredentials(
  company: InstallCompany,
  exchange: TokenExchanger,
): Promise<ResolvedCredentials> {
  if ("credentials" in company) {
    const response = await exchange(
      company.credentials.exchange_token,
      company.credentials.exchange_endpoint,
    );

    const token = response.credentials?.authentication_token;
    if (!token) {
      // Better to fail the install than to write a company with no token:
      // every later Fluid call for that tenant would 401, and the install
      // would look like it worked.
      throw new Error(
        "Token exchange returned no authentication_token; refusing to create a company without one",
      );
    }

    return {
      authenticationToken: token,
      webhookVerificationToken:
        response.credentials?.webhook_verification_token ?? null,
    };
  }

  return {
    authenticationToken: company.authentication_token,
    webhookVerificationToken: company.webhook_verification_token ?? null,
  };
}
