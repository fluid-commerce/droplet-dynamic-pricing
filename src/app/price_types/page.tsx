/**
 * GET /price_types — PriceTypesController#index, plus #destroy.
 *
 * Port of app/views/price_types/index.html.erb in the `application` layout,
 * which is the one with the Price Types / Customers tabs and the flash. Create
 * and edit are their own screens (./new, ./[id]/edit), as they were.
 *
 * Every link and redirect carries `?dri=`. Rails kept the dri in the session
 * after the first request; the cookie that port relies on is read but never
 * written, so without it the next screen would not know the company.
 */

import { redirect } from "next/navigation";

import { ApplicationLayout } from "@/components/layouts/rails-layouts";
import { ConfirmSubmit } from "@/components/price-types/confirm-submit";
import { resolveTenant } from "@/lib/dashboard/dropzone-tenant";
import { assertNotInUse, listPriceTypes } from "@/lib/dashboard/price-types";
import { firstValue, type RawSearchParams } from "@/lib/dashboard/searchparams";
import { prisma } from "@/lib/db";
import { createFluidClient } from "@/lib/fluid";

export const dynamic = "force-dynamic";

/** `created_at.strftime("%Y-%m-%d")`, in UTC like the Rails app. */
const ymd = (iso: string) => iso.slice(0, 10);

export default async function PriceTypesPage({
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
  const q = new URLSearchParams({ dri }).toString();
  const priceTypes = await listPriceTypes(company.id);

  async function remove(formData: FormData) {
    "use server";
    const back = (flash: Record<string, string>) =>
      redirect(`/price_types?${new URLSearchParams({ dri, ...flash })}`);

    const id = BigInt(String(formData.get("id")));
    const existing = await prisma.priceType.findFirst({
      where: { id, companyId: company.id },
    });
    if (!existing) back({ alert: `Price type not found: ${String(id)}` });

    // PriceTypeUseCases::Delete — refuse while any customer carries the name.
    const client = createFluidClient(company.authenticationToken);
    const problem = await assertNotInUse(existing!.name ?? "", (p) =>
      client.listCustomers(p),
    );
    if (problem) {
      back({
        alert: problem.startsWith("Failed")
          ? problem
          : `Cannot delete price type: ${problem}`,
      });
    }

    await prisma.priceType.delete({ where: { id } });
    back({ notice: "Price type deleted" });
  }

  return (
    <ApplicationLayout
      active="price_types"
      dri={dri}
      notice={firstValue(params, "notice")}
      alert={firstValue(params, "alert")}
    >
      <div className="max-w-7xl mx-auto">
        <div className="flex justify-end mb-4">
          <a
            href={`/price_types/new?${q}`}
            className="inline-flex items-center rounded-md bg-indigo-600 px-4 py-2 text-sm font-medium text-white shadow-sm hover:bg-indigo-500 focus:outline-none focus:ring-2 focus:ring-indigo-600 focus:ring-offset-2"
          >
            New Price Type
          </a>
        </div>

        <div className="overflow-x-auto bg-white shadow rounded">
          {priceTypes.length > 0 ? (
            <table className="min-w-full divide-y divide-gray-200">
              <thead className="bg-gray-50">
                <tr>
                  <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                    Name
                  </th>
                  <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                    Date
                  </th>
                  <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                    Actions
                  </th>
                </tr>
              </thead>
              <tbody className="bg-white divide-y divide-gray-200">
                {priceTypes.map((priceType) => (
                  <tr key={priceType.id}>
                    <td className="px-6 py-4 whitespace-nowrap text-gray-900 font-medium">
                      {priceType.name}
                    </td>
                    <td className="px-6 py-4 whitespace-nowrap text-gray-500">
                      {ymd(priceType.createdAt)}
                    </td>
                    <td className="px-6 py-4 whitespace-nowrap">
                      <a
                        href={`/price_types/${priceType.id}/edit?${q}`}
                        className="text-blue-600 hover:text-blue-800"
                      >
                        Edit
                      </a>
                      <form action={remove} className="inline">
                        <input type="hidden" name="id" value={priceType.id} />
                        <ConfirmSubmit
                          message="Are you sure you want to delete this price type?"
                          className="ml-4 text-red-600 hover:text-red-800"
                        >
                          Delete
                        </ConfirmSubmit>
                      </form>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          ) : (
            <div className="text-center py-8">
              <h3 className="text-base font-medium text-gray-900 mb-1">
                No price types found
              </h3>
              <p className="text-sm text-gray-500">
                Create a price type to get started.
              </p>
            </div>
          )}
        </div>
      </div>
    </ApplicationLayout>
  );
}
