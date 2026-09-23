/**
 * GET/POST /admin/integration_setting/edit — Admin::IntegrationSettingsController#edit / #update.
 *
 * Rails had `show`, `edit` and `update` on a singular resource, and `show` is a
 * read-only card summary rather than the same form — see
 * `components/dashboard/integration-settings-show.tsx`. Collapsing the two into
 * one long form, which this port did first, changed the screen.
 *
 * The one intentional divergence — the secret fields render EMPTY rather than
 * carrying the stored Exigo passwords into the markup — and the "blank means
 * keep" rule it forces are explained in
 * src/lib/dashboard/integration-settings-form.ts.
 */

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";

import { IntegrationSettingsForm } from "@/components/dashboard/integration-settings-form";
import { PublicDashboardLayout } from "@/components/layouts/rails-layouts";
import { CompanyNotFound } from "@/components/dashboard/not-found-notice";
import {
  mergeCredentials,
  permitSettings,
  redactCredentials,
  CREDENTIAL_KEYS,
  SETTING_KEYS,
} from "@/lib/dashboard/integration-settings-form";
import { firstValue, type RawSearchParams } from "@/lib/dashboard/searchparams";
import { prisma } from "@/lib/db";

export const dynamic = "force-dynamic";

function asRecord(value: unknown): Record<string, string | undefined> {
  return value && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, string | undefined>)
    : {};
}

export default async function IntegrationSettingEditPage({
  searchParams,
}: {
  searchParams: Promise<RawSearchParams>;
}) {
  const dri = firstValue(await searchParams, "dri");
  if (!dri) return <CompanyNotFound />;

  const company = await prisma.company.findFirst({
    where: { dropletInstallationUuid: dri, active: { not: false } },
  });
  if (!company) return <CompanyNotFound />;

  // findFirst, not findUnique: integration_settings.company_id has no unique
  // index in Rails.
  const row = await prisma.integrationSetting.findFirst({
    where: { companyId: company.id },
    orderBy: { id: "asc" },
  });

  async function save(formData: FormData) {
    "use server";

    // Re-read inside the action. The page's closure is a snapshot, and the row
    // may have been written by the nightly sync between render and submit.
    const current = await prisma.integrationSetting.findFirst({
      where: { companyId: company!.id },
      orderBy: { id: "asc" },
    });

    const submittedCredentials: Record<string, string> = {};
    for (const key of CREDENTIAL_KEYS) {
      submittedCredentials[key] = String(
        formData.get(`credentials.${key}`) ?? "",
      );
    }

    const submittedSettings: Record<string, unknown> = {};
    for (const key of SETTING_KEYS) {
      const value = formData.get(`settings.${key}`);
      if (value !== null) submittedSettings[key] = String(value);
    }

    const credentials = mergeCredentials(
      asRecord(current?.credentials),
      submittedCredentials,
    );
    // Prisma's Json input type will not take `unknown` values; every permitted
    // setting arrives from a form field and is already a string.
    const settings: Record<string, string> = {
      ...asRecord(current?.settings),
    } as Record<string, string>;
    for (const [key, value] of Object.entries(
      permitSettings(submittedSettings),
    )) {
      settings[key] = String(value);
    }
    const enabled = formData.get("enabled") === "on";

    if (current) {
      await prisma.integrationSetting.update({
        where: { id: current.id },
        data: { credentials, settings, enabled },
      });
    } else {
      await prisma.integrationSetting.create({
        data: { companyId: company!.id, credentials, settings, enabled },
      });
    }

    revalidatePath("/admin/integration_setting");
    redirect(
      `/admin/integration_setting?${new URLSearchParams({ dri: dri! })}`,
    );
  }

  const q = new URLSearchParams({ dri }).toString();

  // app/views/admin/integration_settings/edit.html.erb, in the public_dashboard
  // layout it rendered in.
  return (
    <PublicDashboardLayout>
      <div className="flex items-center justify-between mb-6">
        <div className="flex flex-col gap-1">
          <h1 className="font-custom text-3xl font-bold text-gray-600">
            Configure Integration
          </h1>
          <h3 className="text-gray-400">
            Configure Exigo integration for {company.name}
          </h3>
        </div>
        <a
          href={`/admin/home?${q}`}
          className="px-4 py-2 bg-gray-100 hover:bg-gray-200 text-gray-700 font-medium rounded-md"
        >
          ← Back to Home
        </a>
      </div>

      <IntegrationSettingsForm
        action={save}
        company={{
          name: company.name ?? "",
          fluidShop: company.fluidShop,
          fluidCompanyId:
            company.fluidCompanyId === null
              ? null
              : String(company.fluidCompanyId),
          companyDropletUuid: company.companyDropletUuid,
        }}
        enabled={row?.enabled ?? false}
        credentials={redactCredentials(asRecord(row?.credentials))}
        settings={asRecord(row?.settings)}
        dri={dri}
      />
    </PublicDashboardLayout>
  );
}
