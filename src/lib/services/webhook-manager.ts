/**
 * Webhook Manager
 *
 * Port of app/services/webhook_manager.rb. Creates (or updates) the two
 * droplet-level webhooks Fluid calls when a company installs or uninstalls
 * this droplet, and records their Fluid ids in the `fluid_webhook` setting.
 *
 * These are not the per-company webhooks in droplet.config.ts. There are
 * exactly two of them, they belong to the droplet rather than to any company,
 * and they are created once from the admin dashboard.
 */

import type { FluidClient, CreateWebhookPayload } from "@/lib/fluid";
import { fluidWebhookSettings, mergeSettingValues } from "@/lib/settings";

export interface WebhookPair {
  installationWebhook: { id: number | string } | null;
  uninstallationWebhook: { id: number | string } | null;
}

async function attributesFor(event: string): Promise<CreateWebhookPayload> {
  const settings = await fluidWebhookSettings();
  return {
    resource: "droplet",
    url: settings.url,
    active: true,
    auth_token: settings.auth_token,
    event,
    http_method: settings.http_method.toLowerCase() as
      | "post"
      | "get"
      | "put"
      | "delete"
      | "patch",
  };
}

export class WebhookManager {
  constructor(private readonly client: FluidClient) {}

  async create(): Promise<WebhookPair> {
    const installed = (
      await this.client.createWebhook(await attributesFor("installed"))
    ).webhook;
    const uninstalled = (
      await this.client.createWebhook(await attributesFor("uninstalled"))
    ).webhook;

    await mergeSettingValues("fluid_webhook", {
      webhook_installation_id: String(installed.id),
      webhook_uninstallation_id: String(uninstalled.id),
    });

    return {
      installationWebhook: installed,
      uninstallationWebhook: uninstalled,
    };
  }

  async update(): Promise<WebhookPair> {
    const settings = await fluidWebhookSettings();

    // Rails returned nil for a blank id rather than failing, so a droplet whose
    // webhooks were never created can still have its other settings pushed.
    const installed = settings.webhook_installation_id
      ? (
          await this.client.updateWebhook(
            settings.webhook_installation_id,
            await attributesFor("installed"),
          )
        ).webhook
      : null;

    const uninstalled = settings.webhook_uninstallation_id
      ? (
          await this.client.updateWebhook(
            settings.webhook_uninstallation_id,
            await attributesFor("uninstalled"),
          )
        ).webhook
      : null;

    return {
      installationWebhook: installed,
      uninstallationWebhook: uninstalled,
    };
  }
}
