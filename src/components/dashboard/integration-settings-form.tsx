/**
 * Port of app/views/admin/integration_settings/_form.html.erb.
 *
 * Field names and grouping follow the ERB. The difference is the two password
 * inputs: they render with no value, and say so. See
 * src/lib/dashboard/integration-settings-form.ts for why, and for the
 * "blank means keep" rule that makes an untouched save safe.
 */

import type { RedactedCredentials } from "@/lib/dashboard/integration-settings-form";

const TEXT_FIELDS: Array<{ key: string; label: string }> = [
  { key: "exigo_db_host", label: "Database Host" },
  { key: "exigo_db_name", label: "Database Name" },
  { key: "exigo_db_username", label: "Database Username" },
  { key: "api_base_url", label: "API Base URL" },
  { key: "api_username", label: "API Username" },
];

const SECRET_FIELDS: Array<{ key: string; label: string }> = [
  { key: "exigo_db_password", label: "Database Password" },
  { key: "api_password", label: "API Password" },
];

const SETTING_FIELDS: Array<{ key: string; label: string; type: string }> = [
  {
    key: "preferred_customer_type_id",
    label: "Preferred customer type id",
    type: "text",
  },
  {
    key: "retail_customer_type_id",
    label: "Retail customer type id",
    type: "text",
  },
  { key: "api_delay_seconds", label: "API delay (seconds)", type: "text" },
  { key: "snapshots_to_keep", label: "Snapshots to keep", type: "text" },
  { key: "daily_warmup_limit", label: "Daily warmup limit", type: "text" },
  {
    key: "subscription_volume_source",
    label: "Subscription volume source",
    type: "text",
  },
  {
    key: "exigo_preferred_signal",
    label: "Exigo preferred signal",
    type: "text",
  },
  { key: "preferred_source", label: "Preferred source", type: "text" },
  {
    key: "yield_to_enrollment_wholesale",
    label: "Yield to enrollment wholesale",
    type: "text",
  },
  {
    key: "adjust_volumes_for_subscription",
    label: "Adjust volumes for subscription",
    type: "text",
  },
  {
    key: "promote_member_type_on_first_subscription",
    label: "Promote member type on first subscription",
    type: "text",
  },
];

const INPUT =
  "w-full rounded-md border border-input bg-background px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-ring";

export function IntegrationSettingsForm({
  action,
  enabled,
  credentials,
  settings,
  dri,
}: {
  action: (formData: FormData) => Promise<void>;
  enabled: boolean;
  credentials: RedactedCredentials;
  settings: Record<string, string | undefined>;
  dri: string;
}) {
  return (
    <form action={action} className="space-y-10">
      <label className="flex items-center gap-2 text-sm font-medium">
        <input type="checkbox" name="enabled" defaultChecked={enabled} />
        Exigo integration enabled
      </label>

      <section className="space-y-4">
        <h2 className="text-lg font-semibold">Exigo credentials</h2>

        {TEXT_FIELDS.map((field) => (
          <div key={field.key}>
            <label
              htmlFor={`credentials.${field.key}`}
              className="mb-1 block text-sm font-medium"
            >
              {field.label}
            </label>
            <input
              id={`credentials.${field.key}`}
              name={`credentials.${field.key}`}
              defaultValue={String(credentials[field.key] ?? "")}
              className={INPUT}
            />
          </div>
        ))}

        {SECRET_FIELDS.map((field) => {
          const isSet = credentials[`${field.key}_present`] === true;
          return (
            <div key={field.key}>
              <label
                htmlFor={`credentials.${field.key}`}
                className="mb-1 block text-sm font-medium"
              >
                {field.label}
              </label>
              <input
                id={`credentials.${field.key}`}
                name={`credentials.${field.key}`}
                type="password"
                autoComplete="new-password"
                // No defaultValue, ever. This page is reachable with a `dri`
                // alone, and the Rails version put the live Exigo password in
                // the page source.
                placeholder={isSet ? "••••••••" : "Not set"}
                className={INPUT}
              />
              <p className="mt-1 text-xs text-muted-foreground">
                {isSet
                  ? "A password is stored. Leave blank to keep it; type to replace it."
                  : "No password stored yet."}
              </p>
            </div>
          );
        })}
      </section>

      <section className="space-y-4">
        <h2 className="text-lg font-semibold">Settings</h2>

        {SETTING_FIELDS.map((field) => (
          <div key={field.key}>
            <label
              htmlFor={`settings.${field.key}`}
              className="mb-1 block text-sm font-medium"
            >
              {field.label}
            </label>
            <input
              id={`settings.${field.key}`}
              name={`settings.${field.key}`}
              type={field.type}
              defaultValue={settings[field.key] ?? ""}
              className={INPUT}
            />
          </div>
        ))}
      </section>

      <div className="flex items-center gap-4">
        <button
          type="submit"
          className="rounded-md bg-primary px-4 py-2 text-sm font-medium text-primary-foreground"
        >
          Save
        </button>
        <a
          href={`/dashboard?${new URLSearchParams({ dri })}`}
          className="text-sm text-muted-foreground hover:underline"
        >
          Back to dashboard
        </a>
      </div>
    </form>
  );
}
