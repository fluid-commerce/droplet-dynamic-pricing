import { describe, it, expect } from "vitest";

import { validateCallback } from "./validation";

describe("validateCallback", () => {
  it("allows an inactive callback with nothing configured", () => {
    expect(
      validateCallback({ url: null, timeoutInSeconds: null, active: false }),
    ).toEqual([]);
  });

  it("refuses to activate without a URL or a timeout", () => {
    // Port of Callback#validate_active_requirements. An active callback with no
    // URL is registered with Fluid pointing nowhere, and callback routes answer
    // 200 whatever happens, so there is no error path to notice it later.
    const errors = validateCallback({
      url: null,
      timeoutInSeconds: null,
      active: true,
    });
    expect(errors).toHaveLength(2);
    expect(errors.join(" ")).toContain("URL");
    expect(errors.join(" ")).toContain("timeout");
  });

  it("bounds the timeout to 1..20, as the Rails numericality did", () => {
    const base = { url: "https://droplet.test/cb", active: true };
    expect(validateCallback({ ...base, timeoutInSeconds: 0 })).not.toEqual([]);
    expect(validateCallback({ ...base, timeoutInSeconds: 21 })).not.toEqual([]);
    expect(validateCallback({ ...base, timeoutInSeconds: 1.5 })).not.toEqual([]);
    expect(validateCallback({ ...base, timeoutInSeconds: 20 })).toEqual([]);
  });

  it("requires https, because Fluid rejects anything else in production", () => {
    const errors = validateCallback({
      url: "http://droplet.example.com/cb",
      timeoutInSeconds: 20,
      active: true,
    });
    expect(errors.join(" ")).toContain("https");
  });

  it("allows http on localhost for development", () => {
    expect(
      validateCallback({
        url: "http://localhost:3000/api/callbacks/cart-item-added",
        timeoutInSeconds: 20,
        active: true,
      }),
    ).toEqual([]);
  });

  it("rejects a URL that is not absolute", () => {
    const errors = validateCallback({
      url: "/api/callbacks/cart-item-added",
      timeoutInSeconds: 20,
      active: true,
    });
    expect(errors.join(" ")).toContain("absolute");
  });
});
