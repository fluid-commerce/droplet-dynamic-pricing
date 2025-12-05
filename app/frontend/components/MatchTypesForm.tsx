import React from 'react';
import { TextInput } from "~/components/input/TextInput";

interface MatchTypesFormProps {
  companyId: string;
  preferredCustomerTypeId?: string;
}

const MatchTypesForm: React.FC<MatchTypesFormProps> = ({ companyId, preferredCustomerTypeId }) => {
  const handleSubmit = (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    const formData = new FormData(event.currentTarget);
    const data = {
      integration_setting: {
        company_id: companyId,
        preferred_customer_type_id: formData.get('preferredCustomerTypeId'),
      }
    };

    // Send form data to your endpoint
    fetch('/integration_settings', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]')?.getAttribute('content') || '',
      },
      body: JSON.stringify(data),
    })
    .then(response => {
      if (response.ok) {
        alert('Match types saved successfully!');
      } else {
        alert('Error saving match types');
      }
    })
    .catch(error => {
      console.error('Error:', error);
      alert('Error saving match types');
    });
  };

  return (
    <div className="w-full mt-4">
      <form className="space-y-8" onSubmit={handleSubmit}>
        <div className="bg-white rounded-lg p-6 border border-gray-200">
          <div className="mb-4">
            <h2 className="text-lg font-semibold text-gray-900">Match Types</h2>
            <p className="text-sm text-gray-600">Configure your preferred customer type</p>
          </div>

          <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
            <div>
              <label className="block text-sm font-medium text-gray-700 mb-1">
                Preferred Customer Type ID*
              </label>
              <TextInput
                type="text"
                name="preferredCustomerTypeId"
                placeholder="Preferred Customer Type ID"
                defaultValue={preferredCustomerTypeId}
              />
            </div>
          </div>
        </div>

        <div className="flex justify-end gap-3">
          <button
            type="submit"
            className="px-4 py-2 bg-gray-900 hover:bg-gray-800 text-white text-sm font-medium rounded-md focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-blue-500 transition-colors"
          >
            Save
          </button>
        </div>
      </form>
    </div>
  );
};

export default MatchTypesForm;