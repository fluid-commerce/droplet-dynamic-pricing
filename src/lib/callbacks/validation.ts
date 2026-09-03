/**
 * Validation for a `callbacks` row.
 *
 * Port of the Callback model's validations (app/models/callback.rb):
 * name and description present, timeout 1..20, and `active` only allowed when
 * both a url and a timeout are set.
 *
 * The last rule is the load-bearing one: an active callback with no url is
 * registered with Fluid pointing nowhere, and there is no error path for that
 * because a callback route answers 200 whatever happens.
 */

export interface CallbackInput {
  url: string | null;
  timeoutInSeconds: number | null;
  active: boolean;
}

export function validateCallback(input: CallbackInput): string[] {
  const errors: string[] = [];

  if (input.timeoutInSeconds !== null) {
    if (
      !Number.isInteger(input.timeoutInSeconds) ||
      input.timeoutInSeconds <= 0 ||
      input.timeoutInSeconds > 20
    ) {
      errors.push(
        "Timeout in seconds must be a whole number between 1 and 20",
      );
    }
  }

  if (input.active) {
    if (!input.url) errors.push("Active cannot be enabled without a URL");
    if (input.timeoutInSeconds === null) {
      errors.push("Active cannot be enabled without a timeout");
    }
  }

  if (input.url) {
    try {
      const parsed = new URL(input.url);
      // Fluid requires https for callback registrations in production
      // (Callback::Registration validates the format), so a http URL here
      // becomes a 422 at install time, long after it was typed.
      if (parsed.protocol !== "https:" && parsed.hostname !== "localhost") {
        errors.push("URL must be https");
      }
    } catch {
      errors.push("URL is not a valid absolute URL");
    }
  }

  return errors;
}
