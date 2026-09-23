/**
 * Pieces the two ERB list screens — admin/transactions and
 * admin/cart_pricing_events — shared verbatim: the header with its two
 * buttons, and the Previous / Next pagination bar.
 */

export function ListHeader({
  title,
  companyName,
  dri,
}: {
  title: string;
  companyName: string;
  dri: string;
}) {
  const q = new URLSearchParams({ dri }).toString();
  return (
    <div className="flex items-center justify-between mb-6">
      <div className="flex flex-col gap-1">
        <h1 className="font-custom text-4xl font-bold text-gray-600">{title}</h1>
        <h3 className="text-gray-400">{companyName}</h3>
      </div>
      <div className="flex gap-3">
        <a
          href={`/admin/home?${q}`}
          className="px-4 py-2 bg-gray-100 hover:bg-gray-200 text-gray-700 font-medium rounded-md"
        >
          ← Back to Home
        </a>
        <a
          href={`/admin/integration_setting?${q}`}
          className="px-4 py-2 bg-blue-600 hover:bg-blue-700 text-white font-medium rounded-md"
        >
          Integration Settings
        </a>
      </div>
    </div>
  );
}

const PAGE_LINK =
  "px-3 py-1 bg-white hover:bg-gray-100 text-gray-700 border border-gray-300 rounded text-sm";

export function ListPagination({
  path,
  dri,
  page,
  perPage,
  shown,
  totalCount,
  totalPages,
  noun,
}: {
  path: string;
  dri: string;
  page: number;
  perPage: number;
  shown: number;
  totalCount: number;
  totalPages: number;
  noun: string;
}) {
  if (totalPages <= 1) return null;
  const offset = (page - 1) * perPage;
  const href = (p: number) =>
    `${path}?${new URLSearchParams({ dri, page: String(p) })}`;

  return (
    <div className="px-4 py-3 border-t border-gray-200 bg-slate-50">
      <div className="flex items-center justify-between">
        <div className="text-sm text-gray-600">
          Showing {offset + 1}-{Math.min(offset + shown, totalCount)} of{" "}
          {totalCount} {noun}
        </div>
        <div className="flex gap-2">
          {page > 1 ? (
            <a href={href(page - 1)} className={PAGE_LINK}>
              Previous
            </a>
          ) : null}
          {page < totalPages ? (
            <a href={href(page + 1)} className={PAGE_LINK}>
              Next
            </a>
          ) : null}
        </div>
      </div>
    </div>
  );
}
