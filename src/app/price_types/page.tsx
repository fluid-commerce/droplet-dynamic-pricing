/**
 * /price_types — port of PriceTypesController.
 *
 * Index, create, rename and delete on one page. Rails had separate `new` and
 * `edit` screens; the list is short (a handful of rows per company) and the
 * only field is a name, so inline forms replace the round trips without
 * changing what can be done.
 *
 * Rename and delete both ask Fluid whether the type is in use first, and BOTH
 * fail closed. See src/lib/dashboard/price-types.ts.
 */

import { revalidatePath } from "next/cache";

import { DropzoneTabs } from "@/components/dashboard/dropzone-tabs";
import { resolveTenant } from "@/lib/dashboard/dropzone-tenant";
import { assertNotInUse, listPriceTypes } from "@/lib/dashboard/price-types";
import { firstValue, type RawSearchParams } from "@/lib/dashboard/searchparams";
import { prisma } from "@/lib/db";
import { createFluidClient } from "@/lib/fluid";

export const dynamic = "force-dynamic";

const INPUT =
  "rounded-md border border-input bg-background px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-ring";

export default async function PriceTypesPage({
  searchParams,
}: {
  searchParams: Promise<RawSearchParams>;
}) {
  const params = await searchParams;
  const tenant = await resolveTenant(firstValue(params, "dri"));

  if (tenant.error || !tenant.company) {
    return (
      <div className="p-6 font-mono text-sm text-muted-foreground">
        {tenant.error?.message}
      </div>
    );
  }

  const company = tenant.company;
  const priceTypes = await listPriceTypes(company.id);
  const notice = firstValue(params, "notice");
  const alert = firstValue(params, "alert");

  async function create(formData: FormData) {
    "use server";
    const name = String(formData.get("name") ?? "").trim();
    if (!name) return;

    await prisma.priceType.create({ data: { companyId: company.id, name } });
    revalidatePath("/price_types");
  }

  async function rename(formData: FormData) {
    "use server";
    const id = BigInt(String(formData.get("id")));
    const name = String(formData.get("name") ?? "").trim();

    const existing = await prisma.priceType.findFirst({
      where: { id, companyId: company.id },
    });
    if (!existing) return;

    // The CURRENT name is what customers carry, so that is what is checked.
    const client = createFluidClient(company.authenticationToken);
    const inUse = await assertNotInUse(existing.name ?? "", (p) =>
      client.listCustomers(p),
    );
    if (inUse) {
      revalidatePath("/price_types");
      return;
    }

    await prisma.priceType.update({ where: { id }, data: { name } });
    revalidatePath("/price_types");
  }

  async function remove(formData: FormData) {
    "use server";
    const id = BigInt(String(formData.get("id")));

    const existing = await prisma.priceType.findFirst({
      where: { id, companyId: company.id },
    });
    if (!existing) return;

    const client = createFluidClient(company.authenticationToken);
    const inUse = await assertNotInUse(existing.name ?? "", (p) =>
      client.listCustomers(p),
    );
    if (inUse) {
      revalidatePath("/price_types");
      return;
    }

    await prisma.priceType.delete({ where: { id } });
    revalidatePath("/price_types");
  }

  return (
    <main className="mx-auto max-w-4xl p-6">
      <DropzoneTabs active="/price_types" />

      <h1 className="mb-1 text-2xl font-bold tracking-tight">Price Types</h1>
      <p className="mb-6 text-sm text-muted-foreground">{company.name}</p>

      {notice ? (
        <p className="mb-4 rounded-md bg-green-50 px-4 py-2 text-sm text-green-800">
          {notice}
        </p>
      ) : null}
      {alert ? (
        <p className="mb-4 rounded-md bg-red-50 px-4 py-2 text-sm text-red-800">
          {alert}
        </p>
      ) : null}

      <form action={create} className="mb-8 flex gap-2">
        <input
          name="name"
          placeholder="New price type"
          className={INPUT}
          required
        />
        <button
          type="submit"
          className="rounded-md bg-primary px-4 py-2 text-sm font-medium text-primary-foreground"
        >
          Add
        </button>
      </form>

      {priceTypes.length === 0 ? (
        <p className="text-sm text-muted-foreground">No price types yet.</p>
      ) : (
        <ul className="divide-y rounded-lg border">
          {priceTypes.map((priceType) => (
            <li key={priceType.id} className="flex items-center gap-2 p-3">
              <form action={rename} className="flex flex-1 gap-2">
                <input type="hidden" name="id" value={priceType.id} />
                <input
                  name="name"
                  defaultValue={priceType.name}
                  className={`${INPUT} flex-1`}
                />
                <button
                  type="submit"
                  className="text-sm text-indigo-600 hover:underline"
                >
                  Save
                </button>
              </form>
              <form action={remove}>
                <input type="hidden" name="id" value={priceType.id} />
                <button
                  type="submit"
                  className="text-sm text-red-600 hover:underline"
                >
                  Delete
                </button>
              </form>
            </li>
          ))}
        </ul>
      )}
    </main>
  );
}
