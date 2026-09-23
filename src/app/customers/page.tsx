/**
 * /customers — CustomersController#index and #update.
 *
 * Port of app/views/customers/index.html.erb in the `application` layout (the
 * Price Types / Customers tabs and the flash). The rows come from Fluid, so the
 * page paginates the way `GET /api/customers` does, from its `meta` block.
 *
 * Two things differ from Rails, neither of them visible:
 *  - the price type is re-checked against this company's own types before it
 *    is written, since it lands in `metadata.customer_type`, the key the
 *    pricing engine reads (Rails wrote whatever the form sent);
 *  - every link and redirect carries `?dri=`, because the cookie meant to
 *    replace Rails' session is read but never written.
 */

import { redirect } from "next/navigation";

import { ApplicationLayout } from "@/components/layouts/rails-layouts";
import { resolveTenant } from "@/lib/dashboard/dropzone-tenant";
import { listPriceTypes } from "@/lib/dashboard/price-types";
import { firstValue, type RawSearchParams } from "@/lib/dashboard/searchparams";
import { createFluidClient } from "@/lib/fluid";

export const dynamic = "force-dynamic";

const DEFAULT_PER_PAGE = 25;
const PAGE_LINK =
  "inline-flex items-center rounded-md bg-gray-100 px-4 py-2 text-sm font-medium text-gray-800 hover:bg-gray-200";

function str(value: unknown): string {
  return value === null || value === undefined ? "" : String(value);
}

function toInt(value: unknown, fallback: number): number {
  const n = Number.parseInt(str(value), 10);
  return Number.isFinite(n) ? n : fallback;
}

/** `metadata["customer_type"] || metadata.dig("metadata", "customer_type")`. */
function customerTypeOf(customer: Record<string, unknown>): string {
  const metadata = (customer["metadata"] ?? {}) as Record<string, unknown>;
  const nested = (metadata["metadata"] ?? {}) as Record<string, unknown>;
  return str(metadata["customer_type"] || nested["customer_type"]);
}

export default async function CustomersPage({
  searchParams,
}: {
  searchParams: Promise<RawSearchParams>;
}) {
  const params = await searchParams;
  const tenant = await resolveTenant(firstValue(params, "dri"));

  if (tenant.error || !tenant.company || !tenant.dri) {
    return (
      <div className="p-6 font-mono text-sm text-muted-foreground">
        {tenant.error?.message}
      </div>
    );
  }

  const company = tenant.company;
  const dri = tenant.dri;
  const page = toInt(firstValue(params, "page"), 1) || 1;
  const perPageParam = firstValue(params, "per_page");
  const perPage = toInt(perPageParam, DEFAULT_PER_PAGE) || DEFAULT_PER_PAGE;

  const client = createFluidClient(company.authenticationToken);
  const [response, priceTypes] = await Promise.all([
    client.listCustomers({ page, per_page: perPage }),
    listPriceTypes(company.id),
  ]);

  const customers = response.customers ?? [];
  const meta = response.meta;

  const pageHref = (p: number) => {
    const query = new URLSearchParams({ dri, page: String(p) });
    if (perPageParam) query.set("per_page", perPageParam);
    return `/customers?${query}`;
  };

  async function setPriceType(formData: FormData) {
    "use server";
    const back = (flash: Record<string, string>) =>
      redirect(`/customers?${new URLSearchParams({ dri, page: String(page), ...flash })}`);

    const customerId = String(formData.get("customer_id") ?? "");
    const customerType = String(formData.get("customer_type") ?? "");
    if (!customerId) back({ alert: "Failed to update customer: missing customer" });

    // Re-resolve rather than trust the closure: a server action is a POST
    // endpoint of its own, and by now the installation may be gone.
    const current = await resolveTenant(dri);
    if (current.error || !current.company) {
      back({ alert: "Failed to update customer: company not found" });
    }

    // The select offers this company's price types and "Unassigned". Anything
    // else is a forged POST, and it would silently change what a customer pays.
    const allowed = new Set(
      (await listPriceTypes(current.company!.id)).map((type) => type.name),
    );
    if (customerType !== "" && !allowed.has(customerType)) {
      back({ alert: `Failed to update customer: unknown price type ${customerType}` });
    }

    try {
      const inner = createFluidClient(current.company!.authenticationToken);
      await inner.appendCustomerMetadata(customerId, {
        customer_type: customerType,
      });
    } catch (error) {
      back({
        alert: `Failed to update customer: ${
          error instanceof Error ? error.message : String(error)
        }`,
      });
    }

    back({ notice: "Customer updated" });
  }

  const currentPage = toInt(meta?.["current_page"], 1) || 1;
  const totalPages = toInt(meta?.["total_pages"], 1) || 1;

  return (
    <ApplicationLayout
      active="customers"
      dri={dri}
      notice={firstValue(params, "notice")}
      alert={firstValue(params, "alert")}
    >
      <div className="max-w-7xl mx-auto">
        <div className="overflow-x-auto bg-white shadow rounded">
          {customers.length === 0 ? (
            <div className="p-8 text-center">
              <h3 className="text-base font-medium text-gray-900 mb-1">
                No customers found
              </h3>
              <p className="text-sm text-gray-500">
                Once customers appear, you can manage their type here.
              </p>
            </div>
          ) : (
            <table className="min-w-full divide-y divide-gray-200 text-sm">
              <thead className="bg-gray-50">
                <tr>
                  <th className="px-6 py-3 text-left font-medium text-gray-500 uppercase tracking-wider">
                    Full Name
                  </th>
                  <th className="px-6 py-3 text-left font-medium text-gray-500 uppercase tracking-wider">
                    Active
                  </th>
                  <th className="px-6 py-3 text-left font-medium text-gray-500 uppercase tracking-wider">
                    Customer Type
                  </th>
                </tr>
              </thead>
              <tbody className="bg-white divide-y divide-gray-200">
                {customers.map((customer) => {
                  const id = str(customer["id"]);
                  return (
                    <tr key={id} className="hover:bg-gray-50">
                      <td className="px-6 py-4 whitespace-nowrap text-gray-900 font-medium">
                        {str(customer["full_name"])}
                      </td>
                      <td className="px-6 py-4 whitespace-nowrap">
                        {customer["active"] ? (
                          <span className="inline-flex items-center rounded-full bg-green-100 px-2 py-1 text-xs font-semibold text-green-800">
                            Yes
                          </span>
                        ) : (
                          <span className="inline-flex items-center rounded-full bg-gray-200 px-2 py-1 text-xs font-semibold text-gray-800">
                            No
                          </span>
                        )}
                      </td>
                      <td className="px-6 py-4 whitespace-nowrap">
                        <form
                          action={setPriceType}
                          className="flex items-center gap-3"
                        >
                          <input type="hidden" name="customer_id" value={id} />
                          <select
                            name="customer_type"
                            defaultValue={customerTypeOf(customer)}
                            className="w-56 rounded-md border border-gray-300 bg-white px-3 py-2 text-sm shadow-sm focus:border-indigo-500 focus:outline-none focus:ring-2 focus:ring-indigo-500"
                          >
                            <option value="">Unassigned</option>
                            {priceTypes.map((priceType) => (
                              <option key={priceType.id} value={priceType.name}>
                                {priceType.name}
                              </option>
                            ))}
                          </select>
                          <input
                            type="submit"
                            value="Save"
                            className="inline-flex items-center rounded-md bg-indigo-600 px-3 py-2 text-sm font-medium text-white shadow-sm hover:bg-indigo-500 focus:outline-none focus:ring-2 focus:ring-indigo-600 focus:ring-offset-2"
                          />
                        </form>
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          )}
        </div>

        {meta && Object.keys(meta).length > 0 ? (
          <div className="mt-4 flex items-center justify-between">
            <div>
              <span className="text-sm text-gray-600">
                Page {str(meta["current_page"])} of {str(meta["total_pages"])}
              </span>
            </div>
            <div className="space-x-2">
              {currentPage > 1 ? (
                <a href={pageHref(currentPage - 1)} className={PAGE_LINK}>
                  Previous
                </a>
              ) : null}
              {currentPage < totalPages ? (
                <a href={pageHref(currentPage + 1)} className={PAGE_LINK}>
                  Next
                </a>
              ) : null}
            </div>
          </div>
        ) : null}
      </div>
    </ApplicationLayout>
  );
}
