/**
 * Port of app/views/admin/integration_settings/show.html.erb.
 *
 * A read-only summary in cards, with editing on its own screen — not the single
 * long form this port first shipped. The structure is the screen: a merchant
 * opens this to check what is configured, and only occasionally to change it.
 *
 * Passwords render as `••••••••` when set and `-` when not, exactly as the ERB
 * did. That was already true of the original SHOW page; the leak was in `edit`,
 * whose `password_field_tag` carried the real value into a `value=` attribute.
 */

import type { ReactNode } from "react";

export interface ShowCompany {
  name: string;
  fluidShop: string | null;
  fluidCompanyId: string | null;
  companyDropletUuid: string | null;
}

export interface ShowSettings {
  enabled: boolean;
  persisted: boolean;
  updatedAgo: string | null;
  credentials: Record<string, string | undefined>;
  preferredCustomerTypeId: string;
  retailCustomerTypeId: string;
  apiDelaySeconds: number;
  snapshotsToKeep: number;
  dailyWarmupLimit: number;
  adjustVolumesForSubscription: boolean;
  subscriptionVolumeSource: string;
}

function Card({
  title,
  children,
  className = "",
}: {
  title: string;
  children: ReactNode;
  className?: string;
}) {
  return (
    <div
      className={`rounded-lg border border-gray-200 bg-white p-6 ${className}`}
    >
      <h3 className="mb-4 font-semibold text-gray-700">{title}</h3>
      {children}
    </div>
  );
}

function Field({
  label,
  value,
  mono = false,
}: {
  label: string;
  value: ReactNode;
  mono?: boolean;
}) {
  return (
    <div>
      <span className="text-gray-500">{label}:</span>
      <span className={`ml-2 text-gray-900 ${mono ? "font-mono text-xs" : ""}`}>
        {value}
      </span>
    </div>
  );
}

/** `credentials[key].present? ? "••••••••" : "-"`. */
function secret(value: string | undefined): string {
  return value !== undefined && value.trim() !== "" ? "••••••••" : "-";
}

export function IntegrationSettingsShow({
  company,
  settings,
  dri,
}: {
  company: ShowCompany;
  settings: ShowSettings;
  dri: string;
}) {
  const q = new URLSearchParams({ dri }).toString();
  const credential = (key: string) => settings.credentials[key] || "-";

  return (
    <>
      <div className="mb-6 flex items-center justify-between">
        <div className="flex flex-col gap-1">
          <h1 className="text-3xl font-bold text-gray-600">
            Integration Settings
          </h1>
          <h3 className="text-gray-400">
            Configure Exigo integration for {company.name}
          </h3>
        </div>
        <div className="flex gap-3">
          <a
            href={`/admin/home?${q}`}
            className="rounded-md bg-gray-100 px-4 py-2 font-medium text-gray-700 hover:bg-gray-200"
          >
            ← Back to Home
          </a>
          <a
            href={`/admin/integration_setting/edit?${q}`}
            className="rounded-md bg-blue-600 px-4 py-2 font-medium text-white hover:bg-blue-700"
          >
            Edit Settings
          </a>
        </div>
      </div>

      <Card title="Company Information" className="mb-6">
        <div className="grid grid-cols-2 gap-4 text-sm">
          <Field label="Name" value={company.name} />
          <Field label="Shop" value={company.fluidShop ?? "-"} />
          <Field
            label="Fluid Company ID"
            value={company.fluidCompanyId ?? "-"}
          />
          <Field label="UUID" value={company.companyDropletUuid ?? "-"} mono />
        </div>
      </Card>

      <Card title="Integration Status" className="mb-6">
        <div className="flex items-center gap-4 text-sm">
          <div>
            <span className="text-gray-500">Status:</span>
            {settings.enabled ? (
              <span className="ml-2 inline-flex items-center rounded bg-green-100 px-3 py-1 text-sm font-medium text-green-800">
                ✓ Enabled
              </span>
            ) : (
              <span className="ml-2 inline-flex items-center rounded bg-gray-100 px-3 py-1 text-sm font-medium text-gray-600">
                Disabled
              </span>
            )}
          </div>
          {settings.persisted && settings.updatedAgo ? (
            <div>
              <span className="text-gray-500">Last Updated:</span>
              <span className="ml-2 text-gray-700">{settings.updatedAgo}</span>
            </div>
          ) : null}
        </div>
      </Card>

      {settings.persisted && settings.enabled ? (
        <>
          <div className="grid grid-cols-2 gap-6">
            <Card title="Database Configuration">
              <div className="space-y-2 text-sm">
                <Field label="Host" value={credential("exigo_db_host")} />
                <Field label="Database" value={credential("exigo_db_name")} />
                <Field
                  label="Username"
                  value={credential("exigo_db_username")}
                />
                <Field
                  label="Password"
                  value={secret(settings.credentials["exigo_db_password"])}
                />
              </div>
            </Card>

            <Card title="API Configuration">
              <div className="space-y-2 text-sm">
                <Field label="Base URL" value={credential("api_base_url")} />
                <Field label="Username" value={credential("api_username")} />
                <Field
                  label="Password"
                  value={secret(settings.credentials["api_password"])}
                />
              </div>
            </Card>
          </div>

          <Card title="Integration Settings" className="mt-6">
            <div className="grid grid-cols-3 gap-4 text-sm">
              <Field
                label="Preferred Customer Type ID"
                value={settings.preferredCustomerTypeId}
              />
              <Field
                label="Retail Customer Type ID"
                value={settings.retailCustomerTypeId}
              />
              <Field label="API Delay" value={`${settings.apiDelaySeconds}s`} />
              <Field
                label="Snapshots to Keep"
                value={settings.snapshotsToKeep}
              />
              <Field
                label="Daily Warmup Limit"
                value={settings.dailyWarmupLimit.toLocaleString("en-US")}
              />
              <Field
                label="Adjust Volumes for Subscription"
                value={
                  settings.adjustVolumesForSubscription ? "Enabled" : "Disabled"
                }
              />
              <Field
                label="Subscription Volume Source"
                value={settings.subscriptionVolumeSource}
              />
            </div>
          </Card>
        </>
      ) : (
        <div className="rounded-lg border border-yellow-200 bg-yellow-50 p-6 text-center">
          <svg
            className="mx-auto mb-3 h-12 w-12 text-yellow-400"
            fill="none"
            stroke="currentColor"
            viewBox="0 0 24 24"
            aria-hidden="true"
          >
            <path
              strokeLinecap="round"
              strokeLinejoin="round"
              strokeWidth={2}
              d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z"
            />
          </svg>
          <h3 className="mb-2 text-lg font-semibold text-yellow-900">
            Integration Not Configured
          </h3>
          <p className="mb-4 text-yellow-700">
            No Exigo integration has been configured for this company yet.
          </p>
          <a
            href={`/admin/integration_setting/edit?${q}`}
            className="inline-flex items-center rounded-md bg-yellow-600 px-4 py-2 font-medium text-white hover:bg-yellow-700"
          >
            Configure Integration
          </a>
        </div>
      )}
    </>
  );
}
