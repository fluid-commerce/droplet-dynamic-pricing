/**
 * Locating the company a webhook payload refers to.
 *
 * Port of WebhookEventJob#find_company, with one addition: the installation
 * uuid is tried first.
 *
 * Rails looked up `company_droplet_uuid` and then `fluid_company_id`. Both are
 * shared across installations — `company_droplet_uuid` is this DROPLET's uuid,
 * identical for every company, so on a database with more than one installed
 * company that first lookup returns an arbitrary row. `droplet_installation_uuid`
 * is the one value that identifies a single installation, so it is checked
 * before either.
 *
 * All three are findFirst rather than findUnique: none of these columns has a
 * unique index in db/schema.rb, and the Prisma schema keeps that faithfully.
 */

import { prisma } from "@/lib/db";

export interface CompanyIdentifiers {
  company: {
    fluid_company_id?: number | string;
    company_droplet_uuid?: string;
    droplet_installation_uuid?: string;
  };
}

export async function findCompanyForPayload(payload: CompanyIdentifiers) {
  const { company } = payload;

  if (company.droplet_installation_uuid) {
    const match = await prisma.company.findFirst({
      where: { dropletInstallationUuid: company.droplet_installation_uuid },
    });
    if (match) return match;
  }

  if (company.fluid_company_id !== undefined) {
    const match = await prisma.company.findFirst({
      where: { fluidCompanyId: BigInt(company.fluid_company_id) },
    });
    if (match) return match;
  }

  // `company_droplet_uuid` is DELIBERATELY not a fallback.
  //
  // It identifies the DROPLET, and every installation of this droplet carries
  // the same value — so `findFirst` on it returns an arbitrary tenant, not the
  // one the event is about. A correctly signed `droplet.uninstalled` carrying
  // only that field would therefore deactivate some other company and delete
  // its callback registrations. Tenant selection must use a tenant-specific
  // identifier or fail.
  return null;
}
