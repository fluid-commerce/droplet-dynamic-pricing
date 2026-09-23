/**
 * Port of app/views/admin/integration_settings/_form.html.erb — the same
 * sections, labels, help text, defaults, controls and classes, in the same
 * order, so the screen a merchant sees is the one they had.
 *
 * Two things differ, neither of them visible:
 *
 *  - The password inputs carry no value. Rails' `password_field_tag` put the
 *    live Exigo passwords into a `value=` attribute on a page reachable with a
 *    `dri` alone. Here the field is empty with the same `••••••••` placeholder,
 *    and a blank submission keeps the stored password — which is what saving
 *    the Rails form untouched did. See src/lib/dashboard/integration-settings-form.ts.
 *
 *  - Field names are `settings.<key>` / `credentials.<key>` rather than Rails'
 *    bracketed params, because that is what the server action reads.
 *
 * Each toggle is a checkbox FOLLOWED by a hidden "0" of the same name, which is
 * Rails' `hidden_field_tag` + `check_box_tag` pair in the order FormData needs:
 * `formData.get` returns the FIRST value, so a checked box yields "1" and an
 * unchecked one falls through to "0". Without the hidden field an unchecked box
 * submits nothing, and because the save MERGES onto the stored settings, the
 * old value would survive — a toggle that could never be turned off.
 */

import type { RedactedCredentials } from "@/lib/dashboard/integration-settings-form";
import {
  CUSTOMER_TYPE_EXIGO_PREFERRED_SIGNAL,
  DEFAULT_EXIGO_PREFERRED_SIGNAL,
  DEFAULT_PREFERRED_SOURCE,
  DEFAULT_SUBSCRIPTION_VOLUME_SOURCE,
  FLUID_MEMBER_TYPE_PREFERRED_SOURCE,
  PREFERRED_CUSTOMER_VOLUME_SOURCE,
} from "@/lib/integration-settings";
import { castBoolean } from "@/lib/ruby";

const INPUT =
  "w-full px-3 py-2 border border-gray-300 rounded-md focus:outline-none focus:ring-2 focus:ring-blue-500";
const LABEL = "block text-sm font-medium text-gray-700 mb-1";
const HELP = "text-xs text-gray-500 mt-1";
const TOGGLE = "toggle-checkbox h-6 w-12 rounded-full";

/** `required_creds` in the ERB: the Enable toggle stays disabled until all are set. */
const REQUIRED_CREDENTIALS = [
  "exigo_db_host",
  "exigo_db_name",
  "exigo_db_username",
  "exigo_db_password",
  "api_base_url",
  "api_username",
  "api_password",
] as const;

const SECRET_CREDENTIALS = new Set(["exigo_db_password", "api_password"]);

export interface FormCompany {
  name: string;
  fluidShop: string | null;
  fluidCompanyId: string | null;
  companyDropletUuid: string | null;
}

function credentialPresent(
  credentials: RedactedCredentials,
  key: string,
): boolean {
  if (SECRET_CREDENTIALS.has(key)) {
    return credentials[`${key}_present`] === true;
  }
  const value = credentials[key];
  return typeof value === "string" && value.trim() !== "";
}

/** `settings[key] || default` — Ruby's `||`, where only nil falls through. */
function settingOr(
  settings: Record<string, string | undefined>,
  key: string,
  fallback: string,
): string {
  const value = settings[key];
  return value === undefined || value === null ? fallback : value;
}

/** A Rails toggle: checkbox first, then the hidden "0" it falls back to. */
function Toggle({
  name,
  checked,
  disabled = false,
}: {
  name: string;
  checked: boolean;
  disabled?: boolean;
}) {
  return (
    <>
      <input
        type="checkbox"
        name={name}
        value="1"
        defaultChecked={checked}
        disabled={disabled}
        className={TOGGLE}
      />
      <input type="hidden" name={name} value="0" />
    </>
  );
}

function TextCredential({
  credentials,
  keyName,
  label,
  placeholder,
}: {
  credentials: RedactedCredentials;
  keyName: string;
  label: string;
  placeholder: string;
}) {
  const id = `integration_setting_credentials_${keyName}`;
  return (
    <div>
      <label htmlFor={id} className={LABEL}>
        {label}
      </label>
      <input
        id={id}
        type="text"
        name={`credentials.${keyName}`}
        defaultValue={String(credentials[keyName] ?? "")}
        placeholder={placeholder}
        className={INPUT}
      />
    </div>
  );
}

function SecretCredential({
  keyName,
  label,
}: {
  keyName: string;
  label: string;
}) {
  const id = `integration_setting_credentials_${keyName}`;
  return (
    <div>
      <label htmlFor={id} className={LABEL}>
        {label}
      </label>
      <input
        id={id}
        type="password"
        name={`credentials.${keyName}`}
        // No value, ever — see the header. Blank keeps the stored password.
        autoComplete="new-password"
        placeholder="••••••••"
        className={INPUT}
      />
    </div>
  );
}

export function IntegrationSettingsForm({
  action,
  company,
  enabled,
  credentials,
  settings,
  dri,
}: {
  action: (formData: FormData) => Promise<void>;
  company: FormCompany;
  enabled: boolean;
  credentials: RedactedCredentials;
  settings: Record<string, string | undefined>;
  dri: string;
}) {
  const q = new URLSearchParams({ dri }).toString();
  const credsPresent = REQUIRED_CREDENTIALS.every((key) =>
    credentialPresent(credentials, key),
  );

  return (
    <form action={action} className="space-y-6">
      {/* Company Info (Read-only) */}
      <div className="bg-gray-50 rounded-lg p-4 border border-gray-200">
        <h3 className="font-semibold text-gray-700 mb-2">Company Information</h3>
        <div className="grid grid-cols-2 gap-4 text-sm">
          <div>
            <span className="text-gray-500">Name:</span>
            <span className="text-gray-900 font-medium ml-2">{company.name}</span>
          </div>
          <div>
            <span className="text-gray-500">Shop:</span>
            <span className="text-gray-900 font-medium ml-2">
              {company.fluidShop}
            </span>
          </div>
          <div>
            <span className="text-gray-500">Fluid Company ID:</span>
            <span className="text-gray-900 font-medium ml-2">
              {company.fluidCompanyId}
            </span>
          </div>
          <div>
            <span className="text-gray-500">UUID:</span>
            <span className="text-gray-900 font-mono text-xs ml-2">
              {company.companyDropletUuid}
            </span>
          </div>
        </div>
      </div>

      {/* Enable Toggle */}
      <div className="bg-white rounded-lg p-6 border border-gray-200">
        <div className="flex items-center justify-between">
          <div>
            <h3 className="font-semibold text-gray-700">Enable Integration</h3>
            <p className="text-sm text-gray-500 mt-1">
              Turn on to activate Exigo integration for this company
            </p>
          </div>
          <div className="flex items-center">
            {/* `enabled` is read as `=== "on"` by the save, so it keeps the
                browser's default checkbox value. Disabled until every
                credential is set, as in the ERB; a disabled box submits
                nothing, which saves as off. */}
            <input
              type="checkbox"
              name="enabled"
              defaultChecked={enabled}
              disabled={!credsPresent}
              className={TOGGLE}
            />
          </div>
        </div>
      </div>

      {/* Preferred Source */}
      <div className="bg-white rounded-lg p-6 border border-gray-200">
        <h3 className="font-semibold text-gray-700 mb-1">
          Preferred customer source
        </h3>
        <p className="text-sm text-gray-500 mb-4">
          Where preferred-customer status is read from. Everything below only
          applies while this is set to Exigo.
        </p>
        <select
          name="settings.preferred_source"
          defaultValue={settingOr(
            settings,
            "preferred_source",
            DEFAULT_PREFERRED_SOURCE,
          )}
          className={INPUT}
        >
          <option value={DEFAULT_PREFERRED_SOURCE}>
            Exigo — the customer_type metafield the nightly sync stamps, with an
            Exigo read as fallback (default)
          </option>
          <option value={FLUID_MEMBER_TYPE_PREFERRED_SOURCE}>
            Fluid member type — read member_type_slug from Fluid directly
          </option>
        </select>
        <p className={HELP}>
          On &quot;Fluid member type&quot; the droplet stops querying Exigo for
          this company entirely: the nightly sync skips it, and the callbacks no
          longer read or write the customer_type metafield. Only correct for
          tenants whose connector keeps member types current.
        </p>
      </div>

      {/* Promotion */}
      <div className="bg-white rounded-lg p-6 border border-gray-200">
        <div className="flex items-center justify-between">
          <div className="pr-6">
            <h3 className="font-semibold text-gray-700">
              Promote to preferred on first subscription
            </h3>
            <p className="text-sm text-gray-500 mt-1">
              When on, a customer&apos;s first subscription sets their Fluid
              member type to &quot;preferred&quot; and it is never taken back —
              cancelling, pausing or losing the autoship all leave it in place,
              and the nightly sync stops demoting for this company. Independent
              of the source above, so member types can be seeded before the read
              source is cut over.
            </p>
          </div>
          <div className="flex items-center">
            <Toggle
              name="settings.promote_member_type_on_first_subscription"
              checked={castBoolean(
                settings["promote_member_type_on_first_subscription"],
              )}
            />
          </div>
        </div>
      </div>

      {/* Exigo Database Credentials */}
      <div className="bg-white rounded-lg p-6 border border-gray-200">
        <h3 className="font-semibold text-gray-700 mb-4">
          Exigo Database Credentials
        </h3>
        <div className="grid grid-cols-2 gap-4">
          <TextCredential
            credentials={credentials}
            keyName="exigo_db_host"
            label="Database Host"
            placeholder="db.example.com"
          />
          <TextCredential
            credentials={credentials}
            keyName="exigo_db_name"
            label="Database Name"
            placeholder="exigo_db"
          />
          <TextCredential
            credentials={credentials}
            keyName="exigo_db_username"
            label="Database Username"
            placeholder="db_user"
          />
          <SecretCredential keyName="exigo_db_password" label="Database Password" />
        </div>
      </div>

      {/* Exigo API Credentials */}
      <div className="bg-white rounded-lg p-6 border border-gray-200">
        <h3 className="font-semibold text-gray-700 mb-4">Exigo API Credentials</h3>
        <div className="grid grid-cols-1 gap-4">
          <TextCredential
            credentials={credentials}
            keyName="api_base_url"
            label="API Base URL"
            placeholder="https://api.exigo.com/3.0/"
          />
          <div className="grid grid-cols-2 gap-4">
            <TextCredential
              credentials={credentials}
              keyName="api_username"
              label="API Username"
              placeholder="api_user"
            />
            <SecretCredential keyName="api_password" label="API Password" />
          </div>
        </div>
      </div>

      {/* Integration Settings */}
      <div className="bg-white rounded-lg p-6 border border-gray-200">
        <h3 className="font-semibold text-gray-700 mb-4">Integration Settings</h3>
        <div className="grid grid-cols-2 gap-4">
          <div>
            <label
              htmlFor="integration_setting_settings_preferred_customer_type_id"
              className={LABEL}
            >
              Preferred Customer Type ID
            </label>
            <input
              id="integration_setting_settings_preferred_customer_type_id"
              type="text"
              name="settings.preferred_customer_type_id"
              defaultValue={settingOr(settings, "preferred_customer_type_id", "2")}
              className={INPUT}
            />
            <p className={HELP}>Default: 2</p>
          </div>
          <div>
            <label
              htmlFor="integration_setting_settings_retail_customer_type_id"
              className={LABEL}
            >
              Retail Customer Type ID
            </label>
            <input
              id="integration_setting_settings_retail_customer_type_id"
              type="text"
              name="settings.retail_customer_type_id"
              defaultValue={settingOr(settings, "retail_customer_type_id", "1")}
              className={INPUT}
            />
            <p className={HELP}>Default: 1</p>
          </div>
          <div className="col-span-2">
            <label
              htmlFor="integration_setting_settings_exigo_preferred_signal"
              className={LABEL}
            >
              Exigo preferred signal
            </label>
            <select
              id="integration_setting_settings_exigo_preferred_signal"
              name="settings.exigo_preferred_signal"
              defaultValue={settingOr(
                settings,
                "exigo_preferred_signal",
                DEFAULT_EXIGO_PREFERRED_SIGNAL,
              )}
              className={INPUT}
            >
              <option value={DEFAULT_EXIGO_PREFERRED_SIGNAL}>
                Active autoships — an open AutoOrder with a future run date
                (default)
              </option>
              <option value={CUSTOMER_TYPE_EXIGO_PREFERRED_SIGNAL}>
                Customer type — CustomerTypeID matches the Preferred Customer
                Type ID above
              </option>
            </select>
            <p className={HELP}>
              How preferred-customer status is read out of Exigo, for both the
              nightly sync and the cart callbacks. &quot;Customer type&quot;
              compares against the Preferred Customer Type ID above.
            </p>
          </div>
          <div>
            <label
              htmlFor="integration_setting_settings_api_delay_seconds"
              className={LABEL}
            >
              API Delay (seconds)
            </label>
            <input
              id="integration_setting_settings_api_delay_seconds"
              type="number"
              step="0.1"
              name="settings.api_delay_seconds"
              defaultValue={settingOr(settings, "api_delay_seconds", "0.5")}
              className={INPUT}
            />
            <p className={HELP}>Delay between API requests</p>
          </div>
          <div>
            <label
              htmlFor="integration_setting_settings_snapshots_to_keep"
              className={LABEL}
            >
              Snapshots to Keep
            </label>
            <input
              id="integration_setting_settings_snapshots_to_keep"
              type="number"
              name="settings.snapshots_to_keep"
              defaultValue={settingOr(settings, "snapshots_to_keep", "5")}
              className={INPUT}
            />
            <p className={HELP}>Number of historical snapshots</p>
          </div>
          <div>
            <label
              htmlFor="integration_setting_settings_daily_warmup_limit"
              className={LABEL}
            >
              Daily Warmup Limit
            </label>
            <input
              id="integration_setting_settings_daily_warmup_limit"
              type="number"
              name="settings.daily_warmup_limit"
              defaultValue={settingOr(settings, "daily_warmup_limit", "10000")}
              className={INPUT}
            />
            <p className={HELP}>Maximum warmup items per day</p>
          </div>
        </div>
      </div>

      {/* Enrollment Cart Behavior */}
      <div className="bg-white rounded-lg p-6 border border-gray-200">
        <div className="flex items-center justify-between">
          <div className="pr-6">
            <h3 className="font-semibold text-gray-700">
              Yield to wholesale on enrollment carts
            </h3>
            <p className="text-sm text-gray-500 mt-1">
              When on, dynamic pricing is skipped on BP enrollment carts, so the
              droplet that owns wholesale pricing takes precedence. Only enable
              this for companies that run a separate wholesale-pricing droplet —
              otherwise enrollment carts keep their preferred-customer pricing.
            </p>
          </div>
          <div className="flex items-center">
            <Toggle
              name="settings.yield_to_enrollment_wholesale"
              checked={castBoolean(settings["yield_to_enrollment_wholesale"])}
            />
          </div>
        </div>
      </div>

      {/* Volume Adjustment */}
      <div className="bg-white rounded-lg p-6 border border-gray-200">
        <div className="flex items-center justify-between">
          <div className="pr-6">
            <h3 className="font-semibold text-gray-700">
              Adjust volumes for subscription pricing
            </h3>
            <p className="text-sm text-gray-500 mt-1">
              When on, dynamic pricing also lowers each cart item&apos;s QV/CV
              proportionally to the subscription discount, so volumes reflect the
              subscription price. Leave off for companies whose volumes are
              managed by another droplet.
            </p>
          </div>
          <div className="flex items-center">
            <Toggle
              name="settings.adjust_volumes_for_subscription"
              checked={castBoolean(settings["adjust_volumes_for_subscription"])}
            />
          </div>
        </div>
        <div className="mt-4">
          <label
            htmlFor="integration_setting_settings_subscription_volume_source"
            className={LABEL}
          >
            Volume source
          </label>
          <select
            id="integration_setting_settings_subscription_volume_source"
            name="settings.subscription_volume_source"
            defaultValue={settingOr(
              settings,
              "subscription_volume_source",
              DEFAULT_SUBSCRIPTION_VOLUME_SOURCE,
            )}
            className={INPUT}
          >
            <option value={DEFAULT_SUBSCRIPTION_VOLUME_SOURCE}>
              Price ratio — scale retail volumes by the subscription discount
              (default)
            </option>
            <option value={PREFERRED_CUSTOMER_VOLUME_SOURCE}>
              Preferred customer — use catalog pc_cv/pc_qv directly
            </option>
          </select>
          <p className={HELP}>
            Only applies when the toggle above is on. &quot;Preferred
            customer&quot; writes the catalog&apos;s preferred-customer volumes
            (pc_cv/pc_qv) as-is; if a variant is missing them, it falls back to
            that variant&apos;s retail volumes.
          </p>
        </div>
      </div>

      {/* Actions */}
      <div className="flex justify-between items-center pt-4">
        <a
          href={`/admin/integration_setting?${q}`}
          className="px-4 py-2 text-gray-700 bg-gray-100 hover:bg-gray-200 rounded-md"
        >
          Cancel
        </a>
        <input
          type="submit"
          value="Save Settings"
          className="px-6 py-2 bg-blue-600 hover:bg-blue-700 text-white font-medium rounded-md cursor-pointer"
        />
      </div>
    </form>
  );
}
