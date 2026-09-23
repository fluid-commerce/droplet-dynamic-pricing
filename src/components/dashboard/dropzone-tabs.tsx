/**
 * Port of app/views/shared/_tabs.html.erb — the nav shared by /price_types and
 * /customers. The `dri` is not appended: these two screens keep it in a cookie,
 * as Rails kept it in the session.
 */

const TABS = [
  { name: "Price Types", href: "/price_types" },
  { name: "Customers", href: "/customers" },
];

export function DropzoneTabs({ active }: { active: string }) {
  return (
    <div className="mb-6 border-b border-gray-200">
      <nav className="-mb-px flex space-x-8" aria-label="Tabs">
        {TABS.map((tab) => (
          <a
            key={tab.href}
            href={tab.href}
            className={`whitespace-nowrap border-b-2 px-1 py-4 text-sm font-medium ${
              tab.href === active
                ? "border-indigo-500 text-indigo-600"
                : "border-transparent text-gray-500 hover:border-gray-300 hover:text-gray-700"
            }`}
          >
            {tab.name}
          </a>
        ))}
      </nav>
    </div>
  );
}
