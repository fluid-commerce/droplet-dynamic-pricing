/**
 * Droplet Reinstallation Handler
 *
 * Port of app/jobs/droplet_reinstalled_job.rb — it clears `uninstalled_at` and
 * nothing else.
 *
 * NOTE: this handler is not registered by default, and was not in Rails either
 * (config/initializers/event_handler.rb registers only droplet.installed and
 * droplet.uninstalled). Fluid re-sends `droplet.installed` on a reinstall, and
 * handleDropletInstalled clears `uninstalled_at` itself, so registering this as
 * `droplet.reinstalled` is only useful to a droplet whose Fluid app emits that
 * event. It is ported so the behaviour is not lost, and left unregistered so it
 * does not claim to handle an event that never arrives.
 */

import { z } from "zod";

import { prisma } from "@/lib/db";
import { findCompanyForPayload } from "./find-company";

const reinstallPayloadSchema = z.object({
  company: z.object({
    fluid_company_id: z.union([z.number(), z.string()]).optional(),
    company_droplet_uuid: z.string().optional(),
    droplet_installation_uuid: z.string().optional(),
  }),
});

export async function handleDropletReinstalled(
  payload: unknown,
): Promise<void> {
  const parsed = reinstallPayloadSchema.parse(payload);
  const company = await findCompanyForPayload(parsed);

  if (!company) {
    console.warn(
      "[DropletReinstalled] Company not found for payload:",
      JSON.stringify(parsed.company),
    );
    return;
  }

  await prisma.company.update({
    where: { id: company.id },
    data: { uninstalledAt: null, active: true },
  });
}
