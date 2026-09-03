import Link from "next/link";
import { notFound, redirect } from "next/navigation";
import { revalidatePath } from "next/cache";

import { requirePermission } from "@/lib/auth/require";
import { prisma } from "@/lib/db";
import { validateCallback } from "@/lib/callbacks/validation";

/** Port of app/views/admin/callbacks/edit.html.erb. */
export default async function EditCallbackPage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<{ errors?: string }>;
}) {
  await requirePermission("update", "Callback");

  const { id } = await params;
  const { errors } = await searchParams;
  if (!/^\d+$/.test(id)) notFound();

  const callback = await prisma.callback.findUnique({
    where: { id: BigInt(id) },
  });
  if (!callback) notFound();

  async function update(formData: FormData) {
    "use server";
    await requirePermission("update", "Callback");

    const rawTimeout = String(formData.get("timeout_in_seconds") ?? "").trim();
    const input = {
      url: String(formData.get("url") ?? "").trim() || null,
      timeoutInSeconds: rawTimeout === "" ? null : Number(rawTimeout),
      active: formData.get("active") === "on",
    };

    const validationErrors = validateCallback(input);
    if (validationErrors.length > 0) {
      redirect(
        `/admin/callbacks/${id}/edit?errors=${encodeURIComponent(validationErrors.join(", "))}`,
      );
    }

    await prisma.callback.update({ where: { id: BigInt(id) }, data: input });

    revalidatePath("/admin/callbacks");
    redirect(
      `/admin/callbacks/${id}?notice=${encodeURIComponent("Callback was successfully updated.")}`,
    );
  }

  const errorList = errors ? errors.split(", ") : [];

  return (
    <>
      <div className="mb-6">
        <Link
          href="/admin/callbacks"
          className="text-sm font-medium text-blue-600 hover:text-blue-900"
        >
          ← Back to Callbacks
        </Link>
      </div>

      <div className="rounded-lg border border-gray-100 bg-white p-6">
        <div className="mb-6">
          <h1 className="text-4xl font-bold text-gray-600">Edit Callback</h1>
          <p className="mt-2 text-gray-500">
            Configure callback settings for {callback.name}
          </p>
        </div>

        {errorList.length > 0 ? (
          <div className="mb-6 rounded-md border border-red-200 bg-red-50 p-4">
            <h3 className="text-sm font-medium text-red-800">
              There {errorList.length === 1 ? "was" : "were"}{" "}
              {errorList.length} {errorList.length === 1 ? "error" : "errors"}{" "}
              with your submission:
            </h3>
            <ul className="mt-2 list-disc space-y-1 pl-5 text-sm text-red-700">
              {errorList.map((error) => (
                <li key={error}>{error}</li>
              ))}
            </ul>
          </div>
        ) : null}

        <form action={update}>
          <div className="space-y-6">
            <section className="rounded-lg bg-gray-50 p-4">
              <h3 className="mb-4 text-lg font-medium text-gray-900">
                Callback Configuration
              </h3>

              <div className="grid grid-cols-1 gap-6 lg:grid-cols-2">
                <div>
                  <label
                    htmlFor="url"
                    className="mb-2 block text-sm font-medium text-gray-700"
                  >
                    Callback URL *
                  </label>
                  <input
                    id="url"
                    name="url"
                    type="url"
                    defaultValue={callback.url ?? ""}
                    placeholder="https://example.com/api/callbacks/cart-item-added"
                    className="w-full rounded-md border border-gray-300 px-3 py-2 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 focus:outline-none"
                  />
                  <p className="mt-1 text-sm text-gray-500">
                    The URL Fluid will call. Must be one this droplet serves —
                    an active callback pointing anywhere else is registered and
                    then silently never answered.
                  </p>
                </div>

                <div>
                  <label
                    htmlFor="timeout_in_seconds"
                    className="mb-2 block text-sm font-medium text-gray-700"
                  >
                    Timeout (seconds) *
                  </label>
                  <input
                    id="timeout_in_seconds"
                    name="timeout_in_seconds"
                    type="number"
                    min={1}
                    max={20}
                    defaultValue={callback.timeoutInSeconds ?? ""}
                    placeholder="20"
                    className="w-full rounded-md border border-gray-300 px-3 py-2 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 focus:outline-none"
                  />
                  <p className="mt-1 text-sm text-gray-500">
                    Request timeout in seconds (1-20)
                  </p>
                </div>
              </div>
            </section>

            <section className="rounded-lg bg-gray-50 p-4">
              <h3 className="mb-4 text-lg font-medium text-gray-900">Status</h3>
              <div className="flex items-center">
                <input
                  id="active"
                  name="active"
                  type="checkbox"
                  defaultChecked={callback.active ?? false}
                  className="h-4 w-4 rounded border-gray-300 text-indigo-600 focus:ring-indigo-500"
                />
                <label
                  htmlFor="active"
                  className="ml-3 text-sm font-medium text-gray-700"
                >
                  Active
                </label>
              </div>
              <p className="mt-2 text-sm text-gray-500">
                Active callbacks are registered with Fluid for every company at
                install time. A callback can only be activated once it has both
                a URL and a timeout.
              </p>
            </section>
          </div>

          <div className="mt-8 flex justify-start space-x-3 border-t border-gray-200 pt-6">
            <button
              type="submit"
              className="rounded bg-blue-600 px-4 py-2 font-bold text-white hover:bg-blue-700"
            >
              Update
            </button>
            <Link
              href="/admin/callbacks"
              className="rounded bg-gray-300 px-4 py-2 font-bold text-gray-700 hover:bg-gray-400"
            >
              Cancel
            </Link>
          </div>
        </form>
      </div>
    </>
  );
}
