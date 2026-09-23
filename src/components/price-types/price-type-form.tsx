/**
 * Port of app/views/price_types/_form.html.erb.
 *
 * Rails re-rendered this with the model's errors on a failed create. A server
 * action cannot re-render, so the page is redirected back with the messages in
 * the query string and shows them in the same box.
 */

import { pluralizeErrors } from "@/lib/dashboard/price-types";

export function PriceTypeForm({
  action,
  name,
  persisted,
  errors,
}: {
  action: (formData: FormData) => Promise<void>;
  name: string;
  persisted: boolean;
  errors: string[];
}) {
  return (
    <div className="bg-white rounded-lg p-6 border border-gray-100 mt-6">
      <form action={action}>
        {errors.length > 0 ? (
          <div className="mb-4 rounded-md bg-red-50 p-4 text-red-700">
            <p className="font-medium">
              {pluralizeErrors(errors.length)} prevented saving:
            </p>
            <ul className="list-disc ml-5">
              {errors.map((message) => (
                <li key={message}>{message}</li>
              ))}
            </ul>
          </div>
        ) : null}

        <div className="mb-4">
          <label
            htmlFor="price_type_name"
            className="block text-sm font-medium text-gray-700 mb-1"
          >
            Name
          </label>
          <input
            id="price_type_name"
            type="text"
            name="name"
            defaultValue={name}
            className="block w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500"
          />
        </div>

        <div className="mt-6">
          <input
            type="submit"
            value={persisted ? "Update" : "Create"}
            className="inline-flex items-center rounded-md bg-indigo-600 px-4 py-2 text-sm font-medium text-white shadow-sm hover:bg-indigo-500 focus:outline-none focus:ring-2 focus:ring-indigo-600 focus:ring-offset-2"
          />
        </div>
      </form>
    </div>
  );
}
