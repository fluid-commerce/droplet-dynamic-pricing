/**
 * GET /price_types/:id/edit — PriceTypesController#edit, plus #update.
 *
 * Port of app/views/price_types/edit.html.erb in the `application` layout.
 * Update runs PriceTypeUseCases::Update's order: refuse while any customer
 * carries the CURRENT name, then validate, and report either on the index
 * with an alert, as Rails' redirect_to price_types_path did.
 */

import { notFound, redirect } from "next/navigation";

import { ApplicationLayout } from "@/components/layouts/rails-layouts";
import { PriceTypeForm } from "@/components/price-types/price-type-form";
import { resolveTenant } from "@/lib/dashboard/dropzone-tenant";
import {
  assertNotInUse,
  priceTypeNameErrors,
  toSentence,
} from "@/lib/dashboard/price-types";
import { firstValue, type RawSearchParams } from "@/lib/dashboard/searchparams";
import { prisma } from "@/lib/db";
import { createFluidClient } from "@/lib/fluid";

import { BACK_CLASS } from "../../new/page";

export const dynamic = "force-dynamic";

export default async function EditPriceTypePage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<RawSearchParams>;
}) {
  const query = await searchParams;
  const tenant = await resolveTenant(firstValue(query, "dri"));

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

  const { id: rawId } = await params;
  if (!/^\d+$/.test(rawId)) notFound();
  const id = BigInt(rawId);

  // `@company.price_types.find(params[:id])` — scoped to this company.
  const priceType = await prisma.priceType.findFirst({
    where: { id, companyId: company.id },
  });
  if (!priceType) notFound();

  async function update(formData: FormData) {
    "use server";
    const back = (flash: Record<string, string>) =>
      redirect(`/price_types?${new URLSearchParams({ dri, ...flash })}`);

    const current = await prisma.priceType.findFirst({
      where: { id, companyId: company.id },
    });
    if (!current) back({ alert: `Price type not found: ${String(id)}` });

    const client = createFluidClient(company.authenticationToken);
    const problem = await assertNotInUse(current!.name ?? "", (p) =>
      client.listCustomers(p),
    );
    if (problem) {
      back({
        alert: problem.startsWith("Failed")
          ? problem
          : `Cannot update price type: ${problem}`,
      });
    }

    const name = String(formData.get("name") ?? "").trim();
    const errors = await priceTypeNameErrors(company.id, name, id);
    if (errors.length > 0) back({ alert: toSentence(errors) });

    await prisma.priceType.update({ where: { id }, data: { name } });
    back({ notice: "Price type updated" });
  }

  return (
    <ApplicationLayout
      active="price_types"
      dri={dri}
      notice={firstValue(query, "notice")}
      alert={firstValue(query, "alert")}
    >
      <div className="flex items-center justify-between">
        <h1 className="font-custom text-4xl font-bold text-gray-600">
          Edit Price Type
        </h1>
        <div>
          <a href={`/price_types?${q}`} className={BACK_CLASS}>
            Back
          </a>
        </div>
      </div>

      <PriceTypeForm
        action={update}
        name={priceType.name ?? ""}
        persisted
        errors={[]}
      />
    </ApplicationLayout>
  );
}
