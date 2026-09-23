/**
 * Vitest setup.
 *
 * The environment is assigned at module scope, NOT inside `beforeAll`. Route
 * modules read configuration such as FLUID_WEBHOOK_AUTH_TOKEN once, when they
 * are imported — a test file's top-level `await import("./route")` runs before
 * any `beforeAll` hook fires, so setting them there would leave the route
 * holding undefined and every signed request would be refused.
 */

import { afterAll, beforeEach, afterEach, vi } from "vitest";

process.env.DATABASE_URL =
  "postgresql://test:test@localhost:5432/droplet_dynamic_pricing_test";
process.env.FLUID_API_URL = "https://api.fluid.test";
process.env.FLUID_WEBHOOK_AUTH_TOKEN = "test-webhook-token";
// Deliberately DIFFERENT from FLUID_WEBHOOK_AUTH_TOKEN. In production the two
// differ — the shared token is what this app registers its webhooks with, the
// droplet secret is what Fluid actually signs droplet.installed and
// droplet.uninstalled with. A suite that set them equal would pass against a
// service running on the wrong key, which is the defect this guards.
process.env.FLUID_DROPLET_WEBHOOK_SECRET = "test-droplet-webhook-secret";
process.env.FLUID_DROPLET_URL = "https://droplet.test";
process.env.DROPLET_UUID = "drp_test";
process.env.ADMIN_API_TOKEN = "test-admin-api-token";

afterAll(() => {
  vi.clearAllMocks();
});

beforeEach(() => {
  vi.clearAllMocks();
});

afterEach(() => {
  vi.restoreAllMocks();
});
