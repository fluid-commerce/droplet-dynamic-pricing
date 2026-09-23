/**
 * The integration-settings form's credential handling.
 *
 * Port of Admin::IntegrationSettingsController plus its `_form.html.erb`, with
 * ONE behaviour deliberately not carried across.
 *
 * Rails rendered the stored secrets into the markup:
 *
 *   password_field_tag "integration_setting[credentials][exigo_db_password]",
 *     @integration_setting.credentials["exigo_db_password"]
 *
 * `password_field_tag` with an explicit value emits `value="…"`, so
 * GET /admin/integration_setting/edit?dri=… returned the Exigo production
 * database password — and the Exigo API password — in the page source, with no
 * session required. The `dri` is in the dropzone's iframe URL, so it is visible
 * to anyone who opens devtools on the Fluid admin page. PATCH on the same route
 * is equally open, which also let that `dri` REWRITE a company's credentials.
 *
 * Here the secret fields render empty. That is the only intentional divergence
 * in this screen, and it forces the rule below: with the fields pre-filled, a
 * form submitted untouched re-sent the existing passwords and kept them. Blank
 * fields plus a naive save would wipe them instead. So a blank secret means
 * "keep what is stored", and only a value the operator actually typed replaces
 * one.
 *
 * The `dri`-only tenancy itself is unchanged — see the note in query.ts. Fixing
 * that is a separate change with a separate blast radius.
 */

export const CREDENTIAL_KEYS = [
  "exigo_db_host",
  "exigo_db_username",
  "exigo_db_password",
  "exigo_db_name",
  "api_base_url",
  "api_username",
  "api_password",
] as const;

/** The two that must never reach the browser. */
export const SECRET_CREDENTIAL_KEYS = [
  "exigo_db_password",
  "api_password",
] as const;

export type CredentialKey = (typeof CREDENTIAL_KEYS)[number];

function isBlank(value: string | undefined | null): boolean {
  return value === undefined || value === null || value.trim() === "";
}

export type RedactedCredentials = Record<string, string | boolean>;

/**
 * What the form is allowed to render.
 *
 * Secrets come back as `""`, with a companion `<key>_present` boolean so the
 * page can say "a password is set — leave blank to keep it" without saying
 * what it is.
 */
export function redactCredentials(
  stored: Record<string, string | undefined>,
): RedactedCredentials {
  const out: RedactedCredentials = {};

  for (const key of CREDENTIAL_KEYS) {
    const secret = (SECRET_CREDENTIAL_KEYS as readonly string[]).includes(key);
    out[key] = secret ? "" : (stored[key] ?? "");
    if (secret) out[`${key}_present`] = !isBlank(stored[key]);
  }

  return out;
}

/**
 * Applies a submitted form over the stored credentials.
 *
 * Blank wins for a non-secret — clearing the host is a legitimate edit, and it
 * is visible on the page because that field shows what it holds. Blank LOSES
 * for a secret, because the field is empty on every render and "I did not
 * retype the password" must not read as "delete the password".
 */
export function mergeCredentials(
  stored: Record<string, string | undefined>,
  submitted: Record<string, string | undefined>,
): Record<string, string> {
  const out: Record<string, string> = {};

  for (const key of CREDENTIAL_KEYS) {
    const secret = (SECRET_CREDENTIAL_KEYS as readonly string[]).includes(key);
    const incoming = submitted[key];

    if (secret && isBlank(incoming)) {
      out[key] = stored[key] ?? "";
      continue;
    }

    out[key] = incoming ?? "";
  }

  return out;
}

/**
 * The settings keys `integration_setting_params` permitted. Anything else in
 * the submission is dropped, exactly as strong parameters dropped it.
 */
export const SETTING_KEYS = [
  "preferred_customer_type_id",
  "retail_customer_type_id",
  "api_delay_seconds",
  "snapshots_to_keep",
  "daily_warmup_limit",
  "yield_to_enrollment_wholesale",
  "adjust_volumes_for_subscription",
  "subscription_volume_source",
  "exigo_preferred_signal",
  "preferred_source",
  "promote_member_type_on_first_subscription",
] as const;

export function permitSettings(
  submitted: Record<string, unknown>,
): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const key of SETTING_KEYS) {
    if (key in submitted) out[key] = submitted[key];
  }
  return out;
}
