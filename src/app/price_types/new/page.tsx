/**
 * GET /price_types/new — PriceTypesController#new, plus #create.
 *
 * Port of app/views/price_types/new.html.erb in the `application` layout. A
 * failed create comes back here with the model's messages, as Rails'
 * `render :new` did.
 */

import { redirect } from "next/navigation";

import { ApplicationLayout } from "@/components/layouts/rails-layouts";
import { PriceTypeForm } from "@/components/price-types/price-type-form";
import { resolveTenant } from "@/lib/dashboard/dropzone-tenant";
import { priceTypeNameErrors } from "@/lib/dashboard/price-types";
import { firstValue, type RawSearchParams } from "@/lib/dashboard/searchparams";
import { prisma } from "@/lib/db";

export const dynamic = "force-dynamic";

export const BACK_CLASS =
  "inline-flex items-center rounded-md bg-gray-100 px-4 py-2 text-sm font-medium text-gray-700 shadow-sm hover:bg-gray-200 focus:outline-none focus:ring-2 focus:ring-gray-300 focus:ring-offset-2";

export default async function NewPriceTypePage({
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
  const errors = firstValue(params, "errors");

  async function create(formData: FormData) {
    "use server";
    const name = String(formData.get("name") ?? "").trim();

    const problems = await priceTypeNameErrors(company.id, name);
    if (problems.length > 0) {
      redirect(
        `/price_types/new?${new URLSearchParams({ dri, errors: problems.join("\n"), name })}`,
      );
    }

    await prisma.priceType.create({ data: { companyId: company.id, name } });
    redirect(
      `/price_types?${new URLSearchParams({ dri, notice: "Price type created" })}`,
    );
  }

  return (
    <ApplicationLayout
      active="price_types"
      dri={dri}
      notice={firstValue(params, "notice")}
      alert={firstValue(params, "alert")}
    >
      <div className="flex items-center justify-between">
        <h1 className="font-custom text-4xl font-bold text-gray-600">
          New Price Type
        </h1>
        <div>
          <a href={`/price_types?${q}`} className={BACK_CLASS}>
            Back
          </a>
        </div>
      </div>

      <PriceTypeForm
        action={create}
        name={firstValue(params, "name") ?? ""}
        persisted={false}
        errors={errors ? errors.split("\n") : []}
      />
    </ApplicationLayout>
  );
}
