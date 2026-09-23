/**
 * The two layouts the Rails app rendered its merchant screens in, so every
 * ported screen sits in the same frame it did there.
 *
 * Rails picked the layout per controller:
 *
 *   - `public_dashboard` (app/views/layouts/public_dashboard.html.erb) for the
 *     dashboard, admin home, transactions, cart pricing events and integration
 *     settings — PublicAdminController and DynamicPricingDashboardController.
 *   - `application` (app/views/layouts/application.html.erb) for price types and
 *     customers, which inherit ApplicationController directly. It is the only
 *     one that renders the Price Types / Customers tabs and the notice / alert
 *     flash, which is why those two screens need it.
 *
 * The body's `bg-gray-50` lives in the root layout, as it did on
 * public_dashboard's <body>; the application layout paints its own gradient
 * over the full height.
 */

import type { ReactNode } from "react";

/** app/views/layouts/public_dashboard.html.erb, inside <body>. */
export function PublicDashboardLayout({ children }: { children: ReactNode }) {
  return (
    <main className="min-h-screen w-full">
      <div className="mx-auto max-w-7xl px-4 py-8 sm:px-6 lg:px-8">
        {children}
      </div>
    </main>
  );
}

type Tab = "price_types" | "customers";

/** app/views/shared/_tabs.html.erb. */
function Tabs({ active, dri }: { active: Tab; dri: string }) {
  const q = new URLSearchParams({ dri }).toString();
  const tabs: Array<{ name: string; path: string; key: Tab }> = [
    { name: "Price Types", path: `/price_types?${q}`, key: "price_types" },
    { name: "Customers", path: `/customers?${q}`, key: "customers" },
  ];

  return (
    <div className="mb-6 border-b border-gray-200">
      <nav className="-mb-px flex space-x-8" aria-label="Tabs">
        {tabs.map((tab) => (
          <a
            key={tab.key}
            href={tab.path}
            className={[
              "whitespace-nowrap py-4 px-1 border-b-2 text-sm font-medium",
              tab.key === active
                ? "border-indigo-500 text-indigo-600"
                : "border-transparent text-gray-500 hover:text-gray-700 hover:border-gray-300",
            ].join(" ")}
          >
            {tab.name}
          </a>
        ))}
      </nav>
    </div>
  );
}

/** app/views/layouts/application.html.erb, inside <body>. */
export function ApplicationLayout({
  active,
  dri,
  notice,
  alert,
  children,
}: {
  active: Tab;
  dri: string;
  notice?: string;
  alert?: string;
  children: ReactNode;
}) {
  return (
    <div className="min-h-screen bg-gradient-to-br from-slate-50 to-blue-50">
      <div className="mx-auto max-w-7xl px-6">
        <Tabs active={active} dri={dri} />
        {notice ? (
          <div className="mb-4 rounded-md bg-green-50 p-4 text-green-700">
            {notice}
          </div>
        ) : null}
        {alert ? (
          <div className="mb-4 rounded-md bg-red-50 p-4 text-red-700">
            {alert}
          </div>
        ) : null}
        {children}
      </div>
    </div>
  );
}
