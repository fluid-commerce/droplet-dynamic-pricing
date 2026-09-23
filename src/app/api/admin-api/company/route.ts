/**
 * PATCH /api/admin-api/company
 *
 * Port of AdminApi::CompaniesController#update (app/controllers/admin_api/
 * companies_controller.rb). The ops endpoint for correcting a company row:
 * rename it, repoint its shop, or deactivate a stale install.
 *
 * The path is the kebab-cased Rails path, by the same rule the callbacks
 * followed (`/callbacks/cart_item_added` → `/api/callbacks/cart-item-added`).
 * The `admin_api` namespace is preserved because the distinction is the
 * authentication: the `/admin/*` screens authorise on a `dri` from the
 * dropzone, this namespace on an operator bearer token. That is now the only
 * boundary there is — the Devise session and `src/middleware.ts` are gone — so
 * every route here owns its own authentication, and anything that writes a row
 * with no `company_id` belongs on this side of it.
 */

import { z } from "zod";

import { prisma } from "@/lib/db";
import { authorizeAdminApi, unauthorized } from "@/lib/admin-api";

interface CompanyRow {
  id: bigint;
  fluidCompanyId: bigint | null;
  name: string | null;
  fluidShop: string | null;
  active: boolean | null;
  dropletInstallationUuid: string | null;
}

/**
 * `ActiveModel::Type::Boolean`, which is NOT JS truthiness.
 *
 * Rails treats the strings "false", "0", "f", "off" and "" as false. A caller
 * sending `{"active": "false"}` — which a shell pipeline does trivially —
 * would otherwise reactivate the installation this call meant to disable.
 */
const RUBY_FALSE = new Set(["false", "0", "f", "off", "", "no"]);

function castBoolean(value: unknown): boolean {
  if (typeof value === "boolean") return value;
  if (value === null || value === undefined) return false;
  return !RUBY_FALSE.has(String(value).trim().toLowerCase());
}

function serialize(company: CompanyRow) {
  return {
    id: Number(company.id),
    fluid_company_id:
      company.fluidCompanyId === null ? null : Number(company.fluidCompanyId),
    name: company.name,
    fluid_shop: company.fluidShop,
    active: company.active,
    droplet_installation_uuid: company.dropletInstallationUuid,
  };
}

function bigintOrNull(value: unknown): bigint | null {
  if (typeof value === "bigint") return value;
  if (typeof value === "number" && Number.isInteger(value))
    return BigInt(value);
  if (typeof value === "string" && /^\d+$/.test(value.trim())) {
    return BigInt(value.trim());
  }
  return null;
}

/**
 * The request boundary.
 *
 * Deliberately as loose as the Rails contract this route ports, because the
 * route tests mirror `companies_controller_test.rb` one for one and an ops
 * caller depends on those answers:
 *
 *  - `id` and `fluid_company_id` stay `unknown`. An id that is not id-shaped
 *    is a 404 naming the value, not a 400 — the operator learns which row they
 *    failed to find — so the shape check is `bigintOrNull` below, not here.
 *  - `name` and `fluid_shop` coerce the way `String(...)` did, including a
 *    JSON `null` becoming `"null"`, which is what Rails' permitted params
 *    wrote.
 *  - `active` is cast by `castBoolean`, Rails' boolean cast, at the use site.
 *
 * What the schema does own is the thing a manual check kept getting wrong:
 * the body is an object (not `null`, not an array) and unknown keys are
 * dropped, which is Rails' `permit` behaviour.
 */
const bodySchema = z.object({
  id: z.unknown().optional(),
  fluid_company_id: z.unknown().optional(),
  name: z.coerce.string().optional(),
  fluid_shop: z.coerce.string().optional(),
  active: z.unknown().optional(),
});

type Body = z.infer<typeof bodySchema>;

export async function PATCH(request: Request) {
  if (!authorizeAdminApi(request)) return unauthorized();

  let json: unknown;
  try {
    json = await request.json();
  } catch {
    return Response.json(
      { error: "Body was not a JSON object" },
      { status: 400 },
    );
  }

  const parsed = bodySchema.safeParse(json);
  if (!parsed.success) {
    return Response.json(
      { error: "Body was not a JSON object" },
      { status: 400 },
    );
  }
  const body: Body = parsed.data;

  // Target resolution runs BEFORE the attribute check, mirroring Rails'
  // `find_target_company` then `update_attributes` order. An ops call that is
  // wrong in both ways should hear about the target first — that is the half
  // the operator has to look up.
  let company: CompanyRow | null = null;

  if (body.id !== undefined && body.id !== null && body.id !== "") {
    const id = bigintOrNull(body.id);
    company =
      id === null ? null : await prisma.company.findUnique({ where: { id } });
    if (!company) {
      return Response.json(
        { error: `Company not found for id: ${String(body.id)}` },
        { status: 404 },
      );
    }
  } else if (
    body.fluid_company_id !== undefined &&
    body.fluid_company_id !== null &&
    body.fluid_company_id !== ""
  ) {
    const fluidCompanyId = bigintOrNull(body.fluid_company_id);
    const matches: CompanyRow[] =
      fluidCompanyId === null
        ? []
        : await prisma.company.findMany({
            where: { fluidCompanyId },
            orderBy: { id: "asc" },
          });

    if (matches.length === 0) {
      return Response.json(
        {
          error: `Company not found for fluid_company_id: ${String(body.fluid_company_id)}`,
        },
        { status: 404 },
      );
    }

    // `fluid_company_id` is not unique — a company that reinstalls gets a
    // second row. Guessing which one an ops call meant is how the wrong
    // installation gets deactivated, so it refuses and hands back the ids.
    if (matches.length > 1) {
      return Response.json(
        {
          error:
            `Multiple companies match fluid_company_id: ${String(body.fluid_company_id)}. ` +
            "Re-call with an explicit `id`.",
          candidates: matches.map(serialize),
        },
        { status: 409 },
      );
    }

    // `matches.length > 1` and `=== 0` are both handled above, so exactly one
    // row is left; the cast is what tells `noUncheckedIndexedAccess` so.
    company = matches[0] as CompanyRow;
  } else {
    return Response.json(
      { error: "Provide `fluid_company_id` or `id`" },
      { status: 422 },
    );
  }

  const data: {
    name?: string;
    fluidShop?: string;
    active?: boolean;
  } = {};
  if (body.name !== undefined) data.name = body.name;
  if (body.fluid_shop !== undefined) data.fluidShop = body.fluid_shop;
  if (body.active !== undefined) data.active = castBoolean(body.active);

  if (Object.keys(data).length === 0) {
    return Response.json(
      {
        error:
          "At least one of `name`, `fluid_shop`, or `active` must be provided",
      },
      { status: 422 },
    );
  }

  // Every branch above either assigned `company` or returned, but the compiler
  // follows the assignments rather than the returns.
  if (!company) {
    return Response.json(
      { error: "Provide `fluid_company_id` or `id`" },
      { status: 422 },
    );
  }

  const updated = (await prisma.company.update({
    where: { id: company.id },
    data,
  })) as CompanyRow;

  return Response.json({ company: serialize(updated) });
}
