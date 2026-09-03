import Link from "next/link";
import { notFound } from "next/navigation";

import { requirePermission } from "@/lib/auth/require";
import { prisma } from "@/lib/db";

/** Port of app/views/admin/callbacks/show.html.erb. */
function formatTimestamp(value: Date): string {
  return value.toISOString().replace("T", " ").slice(0, 16) + " UTC";
}

export default async function CallbackShowPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  await requirePermission("read", "Callback");

  const { id } = await params;
  if (!/^\d+$/.test(id)) notFound();

  const callback = await prisma.callback.findUnique({
    where: { id: BigInt(id) },
  });
  if (!callback) notFound();

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
        <div className="mb-8 flex items-start justify-between">
          <div>
            <h1 className="text-4xl font-bold text-gray-600">
              {callback.name}
            </h1>
            <p className="mt-2 text-gray-500">{callback.description}</p>
          </div>
          <div className="flex items-center space-x-3">
            {callback.active ? (
              <span className="inline-flex items-center rounded-full bg-green-100 px-3 py-1 text-sm font-medium text-green-800">
                Active
              </span>
            ) : (
              <span className="inline-flex items-center rounded-full bg-gray-100 px-3 py-1 text-sm font-medium text-gray-800">
                Inactive
              </span>
            )}
            <Link
              href={`/admin/callbacks/${callback.id}/edit`}
              className="rounded bg-blue-600 px-4 py-2 font-bold text-white hover:bg-blue-700"
            >
              Edit
            </Link>
          </div>
        </div>

        <div className="space-y-6">
          <section className="rounded-lg bg-gray-50 p-6">
            <h3 className="mb-4 text-lg font-medium text-gray-900">
              Configuration
            </h3>
            <dl className="grid grid-cols-1 gap-6 md:grid-cols-2">
              <div>
                <dt className="mb-2 block text-sm font-medium text-gray-700">
                  Callback URL
                </dt>
                <dd className="rounded-md border border-gray-300 bg-white p-3 break-all">
                  {callback.url ?? (
                    <span className="text-gray-400 italic">Not configured</span>
                  )}
                </dd>
              </div>
              <div>
                <dt className="mb-2 block text-sm font-medium text-gray-700">
                  Timeout
                </dt>
                <dd className="rounded-md border border-gray-300 bg-white p-3">
                  {callback.timeoutInSeconds !== null ? (
                    `${callback.timeoutInSeconds} seconds`
                  ) : (
                    <span className="text-gray-400 italic">Not configured</span>
                  )}
                </dd>
              </div>
            </dl>
          </section>

          <section className="rounded-lg bg-gray-50 p-6">
            <h3 className="mb-4 text-lg font-medium text-gray-900">Metadata</h3>
            <dl className="grid grid-cols-1 gap-6 md:grid-cols-2">
              <div>
                <dt className="mb-2 block text-sm font-medium text-gray-700">
                  Created
                </dt>
                <dd className="rounded-md border border-gray-300 bg-white p-3">
                  {formatTimestamp(callback.createdAt)}
                </dd>
              </div>
              <div>
                <dt className="mb-2 block text-sm font-medium text-gray-700">
                  Last Updated
                </dt>
                <dd className="rounded-md border border-gray-300 bg-white p-3">
                  {formatTimestamp(callback.updatedAt)}
                </dd>
              </div>
            </dl>
          </section>
        </div>
      </div>
    </>
  );
}
