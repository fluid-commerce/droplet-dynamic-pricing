/**
 * Taking a company over from the Rails droplet's installation.
 */

import { describe, it, expect, vi, beforeEach } from "vitest";

import { companyFixture } from "@/test/factories";

const clients = vi.hoisted(() => new Map<string, Record<string, ReturnType<typeof vi.fn>>>());

vi.mock("@/lib/fluid", async () => {
  const actual = await vi.importActual<typeof import("@/lib/fluid")>(
    "@/lib/fluid",
  );
  return {
    ...actual,
    createFluidClient: (token: string) => clients.get(token),
  };
});

const { FluidError, FluidResourceNotFoundError } = await import("@/lib/fluid");
const { previousInstallationOf, takeOverPreviousInstallation } = await import(
  "./takeover"
);

function fakeClient() {
  return {
    deleteCallback: vi.fn(async () => undefined),
    listWebhooks: vi.fn(async () => ({ webhooks: [] as unknown[] })),
    deleteWebhook: vi.fn(async () => undefined),
    uninstallDropletInstallation: vi.fn(async () => undefined),
  };
}

const railsRow = companyFixture({
  companyDropletUuid: "drp_rails",
  dropletInstallationUuid: "dri_rails",
  authenticationToken: "dit_rails",
  installedCallbackIds: ["cbr_rails_1", "cbr_rails_2"],
});

const nextInstall = {
  droplet_uuid: "drp_next",
  droplet_installation_uuid: "dri_next",
};

describe("previousInstallationOf", () => {
  it("returns the live installation of another droplet", () => {
    expect(previousInstallationOf(railsRow, nextInstall)).toEqual({
      dri: "dri_rails",
      authenticationToken: "dit_rails",
      installedCallbackIds: ["cbr_rails_1", "cbr_rails_2"],
    });
  });

  it("ignores a new company", () => {
    expect(previousInstallationOf(null, nextInstall)).toBeNull();
  });

  it("ignores a reinstall or redelivery of this droplet", () => {
    const ours = companyFixture({
      companyDropletUuid: "drp_next",
      dropletInstallationUuid: "dri_next_old",
    });
    expect(previousInstallationOf(ours, nextInstall)).toBeNull();
  });

  it("ignores another droplet's installation that is already uninstalled", () => {
    const gone = { ...railsRow, uninstalledAt: new Date() };
    expect(previousInstallationOf(gone, nextInstall)).toBeNull();
  });

  it("ignores a row that never recorded its installation", () => {
    const legacy = { ...railsRow, dropletInstallationUuid: null };
    expect(previousInstallationOf(legacy, nextInstall)).toBeNull();
  });
});

describe("takeOverPreviousInstallation", () => {
  let ours: ReturnType<typeof fakeClient>;
  let rails: ReturnType<typeof fakeClient>;

  beforeEach(() => {
    clients.clear();
    ours = fakeClient();
    rails = fakeClient();
    clients.set("dit_rails", rails);
  });

  const previous = {
    dri: "dri_rails",
    authenticationToken: "dit_rails",
    installedCallbackIds: ["cbr_rails_1", "cbr_rails_2"],
  };

  it("deletes the previous callbacks, its subscription webhooks, then uninstalls it", async () => {
    rails.listWebhooks.mockResolvedValue({
      webhooks: [
        { id: 1, resource: "subscription", event: "started", url: "https://rails.example/webhook/subscription_started" },
        { id: 2, resource: "subscription", event: "updated", url: "https://rails.example/webhook/cart_item_updated" },
        // Another droplet's webhook for the same event, at its own path.
        { id: 3, resource: "subscription", event: "started", url: "https://other.example/api/webhooks" },
        { id: 4, resource: "order", event: "created", url: "https://rails.example/webhook/subscription_started" },
      ],
    });

    const result = await takeOverPreviousInstallation(ours as never, previous);

    expect(ours.deleteCallback.mock.calls).toEqual([["cbr_rails_1"], ["cbr_rails_2"]]);
    expect(rails.deleteWebhook.mock.calls).toEqual([["1"], ["2"]]);
    expect(ours.deleteWebhook).not.toHaveBeenCalled();
    expect(ours.uninstallDropletInstallation).toHaveBeenCalledWith("dri_rails");
    expect(result.undeletedCallbackIds).toEqual([]);

    // Uninstall comes last, after both kinds of cleanup.
    const uninstallOrder = ours.uninstallDropletInstallation.mock.invocationCallOrder[0];
    expect(uninstallOrder).toBeGreaterThan(ours.deleteCallback.mock.invocationCallOrder[1]);
    expect(uninstallOrder).toBeGreaterThan(rails.deleteWebhook.mock.invocationCallOrder[1]);
  });

  it("treats an already-deleted registration as done", async () => {
    ours.deleteCallback.mockRejectedValueOnce(
      new FluidResourceNotFoundError("gone", 404, ""),
    );

    const result = await takeOverPreviousInstallation(ours as never, previous);

    expect(result.undeletedCallbackIds).toEqual([]);
  });

  it("reports the registrations it could not delete, and still carries on", async () => {
    ours.deleteCallback.mockRejectedValueOnce(new FluidError("boom", 500, ""));
    rails.listWebhooks.mockRejectedValue(new FluidError("revoked", 401, ""));
    ours.uninstallDropletInstallation.mockRejectedValue(
      new FluidError("forbidden", 403, ""),
    );

    const result = await takeOverPreviousInstallation(ours as never, previous);

    expect(result.undeletedCallbackIds).toEqual(["cbr_rails_1"]);
    expect(ours.deleteCallback).toHaveBeenCalledTimes(2);
    expect(ours.uninstallDropletInstallation).toHaveBeenCalled();
  });
});
