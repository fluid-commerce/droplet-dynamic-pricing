import Link from "next/link";
import { redirect } from "next/navigation";
import { revalidatePath } from "next/cache";

import { Flash } from "@/components/flash";
import { requirePermission } from "@/lib/auth/require";
import { prisma } from "@/lib/db";
import { syncCallbackDefinitions } from "@/lib/callbacks";

function truncate(value: string | null, length: number): string {
  if (!value) return "";
  return value.length > length ? `${value.slice(0, length - 3)}...` : value;
}

/** Port of app/views/admin/callbacks/index.html.erb. */
export default async function CallbacksIndexPage({
  searchParams,
}: {
  searchParams: Promise<{ notice?: string; alert?: string }>;
}) {
  await requirePermission("read", "Callback");
  const { notice, alert } = await searchParams;

  const callbacks = await prisma.callback.findMany({ orderBy: { name: "asc" } });

  async function sync() {
    "use server";
    await requirePermission("manage", "Callback");

    const result = await syncCallbackDefinitions();
    revalidatePath("/admin/callbacks");
    redirect(
      `/admin/callbacks?${result.success ? "notice" : "alert"}=${encodeURIComponent(result.message)}`,
    );
  }

  return (
    <>
      <Flash notice={notice} alert={alert} />

      <div className="flex items-center justify-between">
        <h1 className="text-4xl font-bold text-gray-600">Callbacks</h1>
        <form action={sync}>
          <button
            type="submit"
            className="rounded-md bg-blue-600 px-4 py-2 text-white hover:bg-orange-600"
          >
            Sync Callbacks
          </button>
        </form>
      </div>

      <div className="rounded-lg border border-gray-100 bg-white p-6">
        {callbacks.length === 0 ? (
          <div className="py-8 text-center">
            <h3 className="mb-1 text-base font-medium text-gray-900">
              No callbacks found
            </h3>
            <p className="text-sm text-gray-500">
              Get started by syncing callback definitions from Fluid.
            </p>
          </div>
        ) : (
          <table className="w-full">
            <thead className="border-b border-gray-400 bg-slate-50">
              <tr>
                <th className="pl-2 text-left text-slate-600">Name</th>
                <th className="pl-2 text-left text-slate-600">Description</th>
                <th className="pl-2 text-left text-slate-600">URL</th>
                <th className="pl-2 text-left text-slate-600">Status</th>
                <th className="pl-2 text-left text-slate-600">Actions</th>
              </tr>
            </thead>
            <tbody>
              {callbacks.map((callback) => (
                <tr
                  key={String(callback.id)}
                  className="odd:bg-white even:bg-slate-50 hover:bg-slate-100"
                >
                  <td className="pl-2 text-left font-medium text-gray-600">
                    {callback.name}
                  </td>
                  <td className="pl-2 text-left text-gray-600">
                    {truncate(callback.description, 60)}
                  </td>
                  <td className="pl-2 text-left text-gray-600">
                    {callback.url ? (
                      truncate(callback.url, 40)
                    ) : (
                      <span className="text-gray-400">Not set</span>
                    )}
                  </td>
                  <td className="pl-2 text-left">
                    {callback.active ? (
                      <span className="inline-flex items-center rounded-full bg-green-100 px-2.5 py-0.5 text-xs font-medium text-green-800">
                        Active
                      </span>
                    ) : (
                      <span className="inline-flex items-center rounded-full bg-gray-100 px-2.5 py-0.5 text-xs font-medium text-gray-800">
                        Inactive
                      </span>
                    )}
                  </td>
                  <td className="pl-2 text-left">
                    <div className="flex gap-4">
                      <Link
                        href={`/admin/callbacks/${callback.id}`}
                        className="text-blue-600 hover:text-orange-600"
                      >
                        View
                      </Link>
                      <Link
                        href={`/admin/callbacks/${callback.id}/edit`}
                        className="text-blue-600 hover:text-orange-600"
                      >
                        Edit
                      </Link>
                    </div>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>
    </>
  );
}
