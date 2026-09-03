/**
 * Settings validation.
 *
 * Rails validated the `values` column against the row's own `schema` column
 * with json_schemer, and rejected the save when it did not match. The Next
 * settings endpoint has to do the same, because the Rails controller's
 * `render json: { success: true }` after an unchecked `update` reported success
 * for a save that had silently failed validation.
 */

import { describe, it, expect } from "vitest";

import { validateValues } from "./index";
import { SETTING_DEFAULTS } from "./defaults";

function schemaFor(name: string): Record<string, unknown> {
  const preset = SETTING_DEFAULTS.find((d) => d.name === name);
  if (!preset) throw new Error(`no default named ${name}`);
  return preset.schema;
}

describe("validateValues", () => {
  it("accepts every shipped default's own values", () => {
    // If a default cannot satisfy its own schema, the first save of that row
    // fails and the operator has no way to tell why.
    for (const preset of SETTING_DEFAULTS) {
      const result = validateValues(preset.schema, preset.values);
      expect(result.errors, `${preset.name}: ${result.errors.join(", ")}`)
        .toHaveLength(0);
      expect(result.valid).toBe(true);
    }
  });

  it("rejects values missing a required property", () => {
    const result = validateValues(schemaFor("droplet"), {
      name: "Thing",
      // no embed_url, no active
    });
    expect(result.valid).toBe(false);
    expect(result.errors.join(" ")).toMatch(/embed_url|active/);
  });

  it("rejects a value of the wrong type", () => {
    const result = validateValues(schemaFor("droplet"), {
      name: "Thing",
      embed_url: null,
      active: "yes",
    });
    expect(result.valid).toBe(false);
  });

  it("accepts a nullable field explicitly set to null", () => {
    // Rails spelled these `type: %w[string null]`, which Ajv reads the same way.
    const result = validateValues(schemaFor("droplet"), {
      name: "Thing",
      embed_url: null,
      active: true,
    });
    expect(result.valid).toBe(true);
  });

  it("enforces the fluid_webhook http_method enum", () => {
    const schema = schemaFor("fluid_webhook");
    expect(
      validateValues(schema, {
        url: "https://example.com",
        auth_token: "t",
        http_method: "TRACE",
      }).valid,
    ).toBe(false);
    expect(
      validateValues(schema, {
        url: "https://example.com",
        auth_token: "t",
        http_method: "POST",
      }).valid,
    ).toBe(true);
  });

  it("reports an unusable schema as invalid rather than throwing", () => {
    // json_schemer's errors were rescued in Rails and turned into a validation
    // failure. Same here: a bad schema must not 500 the settings page.
    const result = validateValues({ type: 12345 }, { anything: true });
    expect(result.valid).toBe(false);
  });
});
