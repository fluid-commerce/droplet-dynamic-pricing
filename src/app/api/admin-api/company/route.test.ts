/**
 * PATCH /api/admin-api/company — the ops endpoint.
 *
 * The cases mirror test/controllers/admin_api/companies_controller_test.rb one
 * for one. This endpoint is called by people, from a terminal, against live
 * data, so the contract it answers with is the thing being ported — not just
 * the write it performs.
 */

import { describe, it, expect, vi, beforeEach } from "vitest";

const mockPrisma = vi.hoisted(() => ({
  company: {
    findUnique: vi.fn(),
    findMany: vi.fn(),
    update: vi.fn(),
  },
}));

vi.mock("@/lib/db", () => ({ prisma: mockPrisma, default: mockPrisma }));

const { PATCH } = await import("./route");

const TOKEN = "test-admin-api-token";

const acme = {
  id: 7n,
  fluidCompanyId: 42n,
  name: "Acme",
  fluidShop: "acme.fluid.app",
  active: true,
  dropletInstallationUuid: "dri_acme",
};

function patch(body: unknown, token: string | null = TOKEN): Request {
  return new Request("https://droplet.test/api/admin-api/company", {
    method: "PATCH",
    headers: {
      "content-type": "application/json",
      ...(token === null ? {} : { authorization: `Bearer ${token}` }),
    },
    body: JSON.stringify(body),
  });
}

beforeEach(() => {
  vi.clearAllMocks();
  mockPrisma.company.findUnique.mockResolvedValue(null);
  mockPrisma.company.findMany.mockResolvedValue([]);
  mockPrisma.company.update.mockImplementation(async ({ data }) => ({
    ...acme,
    ...data,
  }));
});

describe("auth", () => {
  it("returns 401 when the bearer token is missing", async () => {
    const response = await PATCH(
      patch({ fluid_company_id: 42, name: "New" }, null),
    );

    expect(response.status).toBe(401);
    expect(mockPrisma.company.update).not.toHaveBeenCalled();
  });

  it("returns 401 when the bearer token is wrong", async () => {
    const response = await PATCH(
      patch({ fluid_company_id: 42, name: "New" }, "not-the-token"),
    );

    expect(response.status).toBe(401);
    expect(mockPrisma.company.update).not.toHaveBeenCalled();
  });

  it("refuses a token that is a prefix of the real one", async () => {
    // `secure_compare` raises on a length mismatch rather than returning false,
    // and the Rails controller let that propagate as a 500. Answering 401 is
    // the same refusal without the noise.
    const response = await PATCH(
      patch({ fluid_company_id: 42, name: "New" }, TOKEN.slice(0, 5)),
    );

    expect(response.status).toBe(401);
  });
});

describe("validation", () => {
  it("returns 422 when no mutable field is provided", async () => {
    mockPrisma.company.findMany.mockResolvedValue([acme]);

    const response = await PATCH(patch({ fluid_company_id: 42 }));

    expect(response.status).toBe(422);
    expect(await response.json()).toEqual({
      error:
        "At least one of `name`, `fluid_shop`, or `active` must be provided",
    });
  });

  it("returns 422 when neither fluid_company_id nor id is provided", async () => {
    const response = await PATCH(patch({ name: "New" }));

    expect(response.status).toBe(422);
    expect(await response.json()).toEqual({
      error: "Provide `fluid_company_id` or `id`",
    });
  });
});

describe("not found", () => {
  it("returns 404 when no company matches fluid_company_id", async () => {
    const response = await PATCH(patch({ fluid_company_id: 999, name: "New" }));

    expect(response.status).toBe(404);
    expect(await response.json()).toEqual({
      error: "Company not found for fluid_company_id: 999",
    });
  });

  it("returns 404 when no company matches an explicit id", async () => {
    const response = await PATCH(patch({ id: 999, name: "New" }));

    expect(response.status).toBe(404);
    expect(await response.json()).toEqual({
      error: "Company not found for id: 999",
    });
  });
});

describe("update", () => {
  it("renames a company (name + fluid_shop)", async () => {
    mockPrisma.company.findMany.mockResolvedValue([acme]);

    const response = await PATCH(
      patch({
        fluid_company_id: 42,
        name: "Renamed",
        fluid_shop: "new.fluid.app",
      }),
    );

    expect(response.status).toBe(200);
    expect(mockPrisma.company.update).toHaveBeenCalledWith({
      where: { id: 7n },
      data: { name: "Renamed", fluidShop: "new.fluid.app" },
    });
    expect(await response.json()).toEqual({
      company: {
        id: 7,
        fluid_company_id: 42,
        name: "Renamed",
        fluid_shop: "new.fluid.app",
        active: true,
        droplet_installation_uuid: "dri_acme",
      },
    });
  });

  it("deactivates a stale install without touching other fields", async () => {
    mockPrisma.company.findMany.mockResolvedValue([acme]);

    const response = await PATCH(
      patch({ fluid_company_id: 42, active: false }),
    );

    expect(response.status).toBe(200);
    expect(mockPrisma.company.update).toHaveBeenCalledWith({
      where: { id: 7n },
      data: { active: false },
    });
  });

  it("casts `active` the way ActiveModel::Type::Boolean does", async () => {
    // Rails cast the STRING "false" to false. A JS truthiness check would read
    // it as true and reactivate the install this call meant to disable.
    mockPrisma.company.findMany.mockResolvedValue([acme]);

    await PATCH(patch({ fluid_company_id: 42, active: "false" }));

    expect(mockPrisma.company.update).toHaveBeenCalledWith({
      where: { id: 7n },
      data: { active: false },
    });
  });

  it("updates by explicit id", async () => {
    mockPrisma.company.findUnique.mockResolvedValue(acme);

    const response = await PATCH(patch({ id: 7, name: "ById" }));

    expect(response.status).toBe(200);
    expect(mockPrisma.company.findUnique).toHaveBeenCalledWith({
      where: { id: 7n },
    });
  });
});

describe("non-unique fluid_company_id guard", () => {
  it("returns 409 with candidate ids when fluid_company_id matches multiple rows", async () => {
    const other = {
      ...acme,
      id: 9n,
      name: "Acme (dup)",
      dropletInstallationUuid: "dri_dup",
    };
    mockPrisma.company.findMany.mockResolvedValue([acme, other]);

    const response = await PATCH(patch({ fluid_company_id: 42, name: "New" }));

    expect(response.status).toBe(409);
    expect(mockPrisma.company.update).not.toHaveBeenCalled();

    const body = await response.json();
    expect(body.error).toContain("Re-call with an explicit `id`");
    expect(body.candidates.map((c: { id: number }) => c.id)).toEqual([7, 9]);
  });
});

describe("the body schema", () => {
  it.each([
    ["null", null],
    ["an array", [{ id: 7, name: "x" }]],
    ["a string", "rename please"],
  ])("answers 400 for %s", async (_label, body) => {
    const response = await PATCH(patch(body));

    expect(response.status).toBe(400);
    expect(mockPrisma.company.update).not.toHaveBeenCalled();
  });

  it("answers 400 for a body that is not JSON at all", async () => {
    const request = new Request("https://droplet.test/api/admin-api/company", {
      method: "PATCH",
      headers: {
        "content-type": "application/json",
        authorization: `Bearer ${TOKEN}`,
      },
      body: "{ not json",
    });

    expect((await PATCH(request)).status).toBe(400);
  });

  it("drops keys Rails would not permit instead of writing them", async () => {
    // `authentication_token` is the `dit_` this row carries. An ops call that
    // happened to include it must not be able to overwrite it.
    mockPrisma.company.findUnique.mockResolvedValue(acme);

    await PATCH(
      patch({ id: 7, name: "Renamed", authentication_token: "dit_attacker" }),
    );

    expect(mockPrisma.company.update).toHaveBeenCalledWith({
      where: { id: 7n },
      data: { name: "Renamed" },
    });
  });
});
