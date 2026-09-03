/**
 * Event handler registration.
 *
 * Mirrors config/initializers/event_handler.rb: droplet.installed and
 * droplet.uninstalled, and nothing else by default.
 */

import { registerHandler } from "@/lib/events";
import { handleDropletInstalled } from "./droplet-installed";
import { handleDropletUninstalled } from "./droplet-uninstalled";

let initialized = false;

export function initializeHandlers(): void {
  if (initialized) return;
  initialized = true;

  registerHandler("droplet.installed", handleDropletInstalled);
  registerHandler("droplet.uninstalled", handleDropletUninstalled);

  // Register a droplet's own handlers here, e.g.
  //   registerHandler("order.created", handleOrderCreated);
}

export { handleDropletInstalled } from "./droplet-installed";
export { handleDropletUninstalled } from "./droplet-uninstalled";
export { handleDropletReinstalled } from "./droplet-reinstalled";
export { findCompanyForPayload } from "./find-company";
