/**
 * The integration-settings form.
 *
 * Rails rendered the stored Exigo DB password and API password into `value=`
 * attributes on a page authenticated by an unsigned `dri`. This port does not
 * carry that across — the secret fields render EMPTY.
 *
 * That change has a consequence which is the whole point of these tests: with
 * the fields pre-filled, submitting the form untouched re-sent the existing
 * passwords and kept them. Blank fields plus a naive save would WIPE the
 * credentials of whichever company opened the page. "Blank means keep" is what
 * preserves the flow.
 */

import { describe, it, expect } from "vitest";

import {
  SECRET_CREDENTIAL_KEYS,
  mergeCredentials,
  redactCredentials,
} from "./integration-settings-form";

const stored = {
  exigo_db_host: "sql.exigo.example",
  exigo_db_username: "svc",
  exigo_db_password: "s3cr3t",
  exigo_db_name: "ExigoDb",
  api_base_url: "https://api.exigo.example",
  api_username: "api-user",
  api_password: "ap1-s3cr3t",
};

describe("redactCredentials", () => {
  it("never returns a secret value", () => {
    const shown = redactCredentials(stored);

    for (const key of SECRET_CREDENTIAL_KEYS) {
      expect(shown[key]).toBe("");
    }
  });

  it("still returns the non-secret fields, which the form must show", () => {
    const shown = redactCredentials(stored);

    expect(shown.exigo_db_host).toBe("sql.exigo.example");
    expect(shown.exigo_db_username).toBe("svc");
    expect(shown.api_base_url).toBe("https://api.exigo.example");
  });

  it("reports whether a secret is set, without revealing it", () => {
    expect(redactCredentials(stored).exigo_db_password_present).toBe(true);
    expect(
      redactCredentials({ ...stored, exigo_db_password: "" })
        .exigo_db_password_present,
    ).toBe(false);
  });
});

describe("mergeCredentials", () => {
  it("keeps the stored secret when the field comes back blank", () => {
    const merged = mergeCredentials(stored, {
      ...stored,
      exigo_db_password: "",
      api_password: "",
    });

    expect(merged.exigo_db_password).toBe("s3cr3t");
    expect(merged.api_password).toBe("ap1-s3cr3t");
  });

  it("replaces a secret that was actually typed", () => {
    const merged = mergeCredentials(stored, {
      ...stored,
      exigo_db_password: "rotated",
    });

    expect(merged.exigo_db_password).toBe("rotated");
  });

  it("treats whitespace as blank rather than as a new password", () => {
    const merged = mergeCredentials(stored, {
      ...stored,
      exigo_db_password: "   ",
    });

    expect(merged.exigo_db_password).toBe("s3cr3t");
  });

  it("lets a NON-secret field be cleared", () => {
    // Only the secrets get the keep-on-blank rule. Emptying the host is a
    // legitimate edit; emptying it by accident is visible on the page, because
    // the field shows what it holds.
    const merged = mergeCredentials(stored, { ...stored, exigo_db_host: "" });

    expect(merged.exigo_db_host).toBe("");
  });

  it("can set a secret for the first time", () => {
    const merged = mergeCredentials(
      { ...stored, exigo_db_password: "" },
      { ...stored, exigo_db_password: "first" },
    );

    expect(merged.exigo_db_password).toBe("first");
  });
});
