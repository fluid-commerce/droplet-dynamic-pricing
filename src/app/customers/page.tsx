/**
 * /customers — port of CustomersController.
 *
 * Lists the company's Fluid customers and lets an operator set each one's
 * price type, which is written to `metadata.customer_type` — the same key the
 * pricing engine reads and the same key /price_types guards against.
 *
 * The rows come from Fluid, not from this droplet's database, so the page is
 * as fast as `GET /api/customers` and paginates the way that endpoint does.
 */

import { revalidatePath } from "next/cache";

import { DropzoneTabs } from "@/components/dashboard/dropzone-tabs";
import { resolveTenant } from "@/lib/dashboard/dropzone-tenant";
import { listPriceTypes } from "@/lib/dashboard/price-types";
import { firstValue, type RawSearchParams } from "@/lib/dashboard/searchparams";
import { createFluidClient } from "@/lib/fluid";

export const dynamic = "force-dynamic";

const DEFAULT_PER_PAGE = 25;

function str(value: unknown): string {
  return value === null || value === undefined ? "" : String(value);
}

export default async function CustomersPage({
  searchParams,
}: {
  searchParams: Promise<RawSearchParams>;
}) {
  const params = await searchParams;
  const dri = firstValue(params, "dri");
  const tenant = await resolveTenant(dri);

  if (tenant.error || !tenant.company) {
    return (
      <div className="p-6 font-mono text-sm text-muted-foreground">
        {tenant.error?.message}
      </div>
    );
  }

  const company = tenant.company;
  const page = Number.parseInt(firstValue(params, "page") ?? "1", 10) || 1;
  const perPage =
    Number.parseInt(firstValue(params, "per_page") ?? "", 10) ||
    DEFAULT_PER_PAGE;

  const client = createFluidClient(company.authenticationToken);
  const [response, priceTypes] = await Promise.all([
    client.listCustomers({ page, per_page: perPage }),
    listPriceTypes(company.id),
  ]);

  // Ruby: `response["customers"] || []`.
  const customers = response.customers ?? [];

  async function setPriceType(formData: FormData) {
    "use server";
    const customerId = String(formData.get("customer_id") ?? "");
    const customerType = String(formData.get("customer_type") ?? "");
    if (!customerId) return;

    // Re-resolve rather than trust the closure. A server action is a POST
    // endpoint of its own: rendering the page once hands out an id that can be
    // replayed later, and by then the installation may be gone. `resolveTenant`
    // now refuses a `dri` whose company uninstall marked inactive.
    const current = await resolveTenant(dri);
    if (current.error || !current.company) return;

    // The select offers the company's own price types and an empty option to
    // clear. Anything else is a forged POST, and this value is written to
    // `metadata.customer_type` — the key the pricing engine reads — so an
    // arbitrary string here silently changes what a customer pays.
    const allowed = new Set(
      (await listPriceTypes(current.company.id)).map((type) => type.name),
    );
    if (customerType !== "" && !allowed.has(customerType)) return;

    const inner = createFluidClient(current.company.authenticationToken);
    // `append_metadata`, not a replace: Fluid merges the key in and leaves the
    // rest of the customer's metadata alone.
    await inner.appendCustomerMetadata(customerId, {
      customer_type: customerType,
    });

    revalidatePath("/customers");
  }

  return (
    <main className="mx-auto max-w-5xl p-6">
      <DropzoneTabs active="/customers" />

      <h1 className="mb-1 text-2xl font-bold tracking-tight">Customers</h1>
      <p className="mb-6 text-sm text-muted-foreground">{company.name}</p>

      {customers.length === 0 ? (
        <p className="text-sm text-muted-foreground">
          No customers on this page.
        </p>
      ) : (
        <table className="w-full text-sm">
          <thead className="border-b text-left text-muted-foreground">
            <tr>
              <th className="py-2 pr-4 font-medium">Name</th>
              <th className="py-2 pr-4 font-medium">Email</th>
              <th className="py-2 pr-4 font-medium">Price type</th>
            </tr>
          </thead>
          <tbody>
            {customers.map((customer) => {
              const id = str(customer["id"]);
              const metadata = (customer["metadata"] ?? {}) as Record<
                string,
                unknown
              >;
              const current = str(metadata["customer_type"]);

              return (
                <tr key={id} className="border-b last:border-0">
                  <td className="py-3 pr-4">
                    {str(customer["first_name"])} {str(customer["last_name"])}
                  </td>
                  <td className="py-3 pr-4 text-muted-foreground">
                    {str(customer["email"])}
                  </td>
                  <td className="py-3 pr-4">
                    <form
                      action={setPriceType}
                      className="flex items-center gap-2"
                    >
                      <input type="hidden" name="customer_id" value={id} />
                      <select
                        name="customer_type"
                        defaultValue={current}
                        className="rounded-md border border-input bg-background px-2 py-1 text-sm"
                      >
                        <option value="">—</option>
                        {priceTypes.map((priceType) => (
                          <option key={priceType.id} value={priceType.name}>
                            {priceType.name}
                          </option>
                        ))}
                      </select>
                      <button
                        type="submit"
                        className="text-sm text-indigo-600 hover:underline"
                      >
                        Save
                      </button>
                    </form>
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      )}

      <div className="mt-6 flex gap-4 text-sm">
        {page > 1 ? (
          <a
            href={`/customers?page=${page - 1}&per_page=${perPage}`}
            className="hover:underline"
          >
            ← Previous
          </a>
        ) : null}
        {customers.length === perPage ? (
          <a
            href={`/customers?page=${page + 1}&per_page=${perPage}`}
            className="hover:underline"
          >
            Next →
          </a>
        ) : null}
      </div>
    </main>
  );
}
