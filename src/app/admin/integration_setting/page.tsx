/**
 * GET /admin/integration_setting — Admin::IntegrationSettingsController#show.
 *
 * A read-only card summary. Editing lives at `/edit`, which is how the original
 * splits it; the first version of this port collapsed both into one long form
 * and that changed what the screen is.
 */

import { CompanyNotFound } from "@/components/dashboard/not-found-notice";
import {
  IntegrationSettingsShow,
  type ShowSettings,
} from "@/components/dashboard/integration-settings-show";
import { firstValue, type RawSearchParams } from "@/lib/dashboard/searchparams";
import { timeAgoInWords } from "@/lib/dashboard/time-ago";
import { prisma } from "@/lib/db";
import { IntegrationSettings } from "@/lib/integration-settings";

export const dynamic = "force-dynamic";

function asRecord(value: unknown): Record<string, string | undefined> {
  return value && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, string | undefined>)
    : {};
}

export default async function IntegrationSettingPage({
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

  const row = await prisma.integrationSetting.findFirst({
    where: { companyId: company.id },
    orderBy: { id: "asc" },
  });
  const settings = new IntegrationSettings(row);

  const view: ShowSettings = {
    enabled: row?.enabled ?? false,
    // `@integration_setting.persisted?` — a company with no row gets the
    // "Integration Not Configured" panel rather than a summary of defaults.
    persisted: row !== null,
    updatedAgo: row ? `${timeAgoInWords(row.updatedAt)} ago` : null,
    credentials: asRecord(row?.credentials),
    preferredCustomerTypeId: settings.preferredCustomerTypeId,
    retailCustomerTypeId: settings.retailCustomerTypeId,
    apiDelaySeconds: settings.apiDelaySeconds,
    snapshotsToKeep: settings.snapshotsToKeep,
    dailyWarmupLimit: settings.dailyWarmupLimit,
    adjustVolumesForSubscription: settings.adjustVolumesForSubscription,
    subscriptionVolumeSource: settings.subscriptionVolumeSource,
  };

  return (
    <main className="mx-auto max-w-6xl p-6">
      <IntegrationSettingsShow
        company={{
          name: company.name ?? "",
          fluidShop: company.fluidShop,
          fluidCompanyId:
            company.fluidCompanyId === null
              ? null
              : String(company.fluidCompanyId),
          companyDropletUuid: company.companyDropletUuid,
        }}
        settings={view}
        dri={dri}
      />
    </main>
  );
}
