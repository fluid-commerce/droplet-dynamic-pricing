/**
 * Price types.
 *
 * Port of PriceTypesController and PriceTypeUseCases::Update / ::Delete.
 *
 * A price type's NAME is the link: customers carry it in
 * `metadata.customer_type`, and the pricing engine reads it back from there.
 * So renaming a type in use orphans every customer pointing at it, and
 * deleting one leaves them pointing at nothing. Both operations ask Fluid
 * first.
 */

import { prisma } from "@/lib/db";

export interface CustomerLister {
  (params: {
    by_metadata: { customer_type: string };
    per_page: number;
  }): Promise<{ customers?: unknown[] }>;
}

/**
 * Returns an error message, or null when the change may proceed.
 *
 * FAILS CLOSED. Rails rescued `FluidClient::Error` into a failure rather than
 * into a pass, and that is load-bearing: an unreachable Fluid read as "nobody
 * is using it" would let an outage delete a price type every customer depends
 * on. Asking for one customer is enough — the question is whether any exists.
 */
export async function assertNotInUse(
  name: string,
  listCustomers: CustomerLister,
): Promise<string | null> {
  try {
    const response = await listCustomers({
      by_metadata: { customer_type: name },
      per_page: 1,
    });

    const customers = response.customers ?? [];
    return customers.length > 0
      ? "it is in use by one or more customers"
      : null;
  } catch (error) {
    return `Failed to check customer usage: ${
      error instanceof Error ? error.message : String(error)
    }`;
  }
}

export async function listPriceTypes(companyId: bigint) {
  const rows = await prisma.priceType.findMany({
    where: { companyId },
    orderBy: { name: "asc" },
  });

  return rows.map((row) => ({ id: String(row.id), name: row.name ?? "" }));
}

/**
 * `store_dri_in_session`, ported onto a cookie.
 *
 * /price_types and /customers link to each other WITHOUT re-appending `?dri=`,
 * so after the first request the stored value is the only thing keeping the
 * tenant. The other dropzone screens carry it in every link and do not need
 * this.
 *
 * A blank `?dri=` falls through rather than overwriting, because `dri.present?`
 * is false for "" in Ruby — an empty parameter must not blank the session.
 */
export function resolveDri(
  paramDri: string | undefined,
  storedDri: string | undefined,
): { dri: string | null; store: boolean } {
  if (paramDri !== undefined && paramDri.trim() !== "") {
    return { dri: paramDri, store: true };
  }
  if (storedDri !== undefined && storedDri.trim() !== "") {
    return { dri: storedDri, store: false };
  }
  return { dri: null, store: false };
}
