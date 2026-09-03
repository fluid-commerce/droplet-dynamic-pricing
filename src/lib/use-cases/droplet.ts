/**
 * Droplet create / update use cases.
 *
 * Port of app/use_cases/droplet_use_case/{base,create,update}.rb — the two
 * actions behind the admin dashboard's "Create Droplet" / "Update Droplet"
 * buttons.
 *
 * The Ruby version wrapped both in an ActiveRecord transaction. That
 * transaction never bought what it looked like it bought: the only writes
 * inside it are settings rows, and the Fluid API calls it interleaves are not
 * transactional, so a rollback left Fluid holding a droplet this app had no
 * uuid for. The order here is the same, but it is honest about being a
 * sequence of remote calls: a failure is reported with whatever succeeded
 * already having succeeded.
 */

import { createFluidClient } from "@/lib/fluid";
import { fluidApiSettings } from "@/lib/settings";
import { DropletManager } from "@/lib/services/droplet-manager";
import { WebhookManager } from "@/lib/services/webhook-manager";

export type UseCaseResult<T> =
  | ({ success: true } & T)
  | { success: false; error: string };

async function managers() {
  const { api_key, base_url } = await fluidApiSettings();
  const client = createFluidClient(api_key, base_url);
  return {
    dropletManager: new DropletManager(client),
    webhookManager: new WebhookManager(client),
  };
}

export async function createDroplet(): Promise<
  UseCaseResult<{ droplet: unknown; webhooks: unknown }>
> {
  try {
    const { dropletManager, webhookManager } = await managers();
    const droplet = await dropletManager.create();
    const webhooks = await webhookManager.create();
    return { success: true, droplet, webhooks };
  } catch (error) {
    return {
      success: false,
      error: error instanceof Error ? error.message : String(error),
    };
  }
}

export async function updateDroplet(): Promise<
  UseCaseResult<{ droplet: unknown; webhooks: unknown }>
> {
  try {
    const { dropletManager, webhookManager } = await managers();
    const droplet = await dropletManager.update();
    const webhooks = await webhookManager.update();
    return { success: true, droplet, webhooks };
  } catch (error) {
    return {
      success: false,
      error: error instanceof Error ? error.message : String(error),
    };
  }
}
