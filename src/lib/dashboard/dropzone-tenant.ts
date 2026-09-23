/**
 * Tenant resolution for the two session-backed dropzone screens.
 *
 * /price_types and /customers store the `dri` and then link to each other
 * without re-appending it, so they need somewhere to keep it. Rails used
 * `session[:dri]`; here it is a cookie with the same lifetime as the iframe.
 */

import { cookies } from "next/headers";

import { prisma } from "@/lib/db";

import { resolveDri } from "./price-types";

export const DRI_COOKIE = "dp_dri";

export interface TenantResult {
  /** True when the `dri` came from the URL rather than the cookie. */
  fromUrl?: boolean;
  company: { id: bigint; name: string; authenticationToken: string } | null;
  /** The message and status Rails answered with, when there is no tenant. */
  error: { message: string; status: number } | null;
  dri: string | null;
}

export async function resolveTenant(
  paramDri: string | undefined,
): Promise<TenantResult> {
  const jar = await cookies();
  const { dri, store } = resolveDri(paramDri, jar.get(DRI_COOKIE)?.value);

  if (!dri) {
    return {
      company: null,
      dri: null,
      error: { message: "DRI parameter is required", status: 400 },
    };
  }

  // The cookie is NOT written here. Next allows `cookies().set` only in a
  // Server Action or Route Handler, and this runs during a page render — doing
  // it here threw "Cookies can only be modified in a Server Action or Route
  // Handler" and answered 500 for every first visit to /price_types and
  // /customers, which are exactly the visits that carry the `?dri=`.
  //
  // `src/middleware.ts` writes it on the response instead, where it is allowed
  // and where it happens before this ever runs. `store` is kept in the return
  // so a caller can tell a first visit from a later one.
  void store;

  const company = await prisma.company.findFirst({
    // A `dri` kept after uninstall must stop working — see require-dri.ts.
    where: { dropletInstallationUuid: dri, active: { not: false } },
  });

  if (!company) {
    return {
      company: null,
      dri,
      error: { message: `Company not found with DRI: ${dri}`, status: 404 },
    };
  }

  return {
    fromUrl: store,
    company: {
      id: company.id,
      name: company.name ?? "",
      authenticationToken: company.authenticationToken,
    },
    dri,
    error: null,
  };
}
