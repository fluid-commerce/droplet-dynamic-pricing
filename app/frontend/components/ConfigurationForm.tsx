import React, { useState } from 'react';
import { TextInput } from "~/components/input/TextInput";
import ConnectionStatusButton from '~/components/ConnectionStatusButton';

interface ConfigurationFormProps {
  companyId: string;
  exigoDbHost?: string;
  dbExigoUsername?: string;
  exigoDbPassword?: string;
  exigoDbName?: string;
}

type ConnectionStatus = 'default' | 'connecting' | 'connected' | 'error';

const ConfigurationForm: React.FC<ConfigurationFormProps> = ({ companyId, exigoDbHost, dbExigoUsername, exigoDbPassword, exigoDbName }) => {
  const [connectionStatus, setConnectionStatus] = useState<ConnectionStatus>('default');

  const handleSubmit = (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    const formData = new FormData(event.currentTarget);
    const data = {
      integration_setting: {
        company_id: companyId,
        exigo_db_host: formData.get('exigoDbHost'),
        db_exigo_username: formData.get('dbExigoUsername'),
        exigo_db_password: formData.get('exigoDbPassword'),
        exigo_db_name: formData.get('exigoDbName'),
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
        alert('Configuration saved successfully!');
      } else {
        alert('Error saving configuration');
      }
    })
    .catch(error => {
      console.error('Error:', error);
      alert('Error saving configuration');
    });
  };

  const handleTestConnection = () => {
    setConnectionStatus('connecting');

    fetch('/integration_settings/test_connection', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]')?.getAttribute('content') || '',
      },
      body: JSON.stringify({company_id: companyId}),
    })
    .then(response => response.json())
    .then(data => {
      if (data.connection) {
        setConnectionStatus('connected');
      } else {
        setConnectionStatus('error');
      }
    })
    .catch(error => {
      console.error('Error:', error);
      setConnectionStatus('error');
    });
  };

  return (
    <div className="w-full mt-4">
      <form className="space-y-8" onSubmit={handleSubmit}>
        <div className="bg-white rounded-lg p-6 border border-gray-200">
          <div className="mb-4">
            <h2 className="text-lg font-semibold text-gray-900">Exigo Database Settings</h2>
            <p className="text-sm text-gray-600">Configure your Exigo database connection settings</p>
          </div>

          <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
            <div>
              <label className="block text-sm font-medium text-gray-700 mb-1">
                Database Host
              </label>
              <TextInput
                type="text"
                name="exigoDbHost"
                placeholder="Database Host"
                defaultValue={exigoDbHost}
              />
            </div>

            <div>
              <label className="block text-sm font-medium text-gray-700 mb-1">
                Username
              </label>
              <TextInput
                type="text"
                name="dbExigoUsername"
                placeholder="Database Username"
                defaultValue={dbExigoUsername}
              />
            </div>

            <div>
              <label className="block text-sm font-medium text-gray-700 mb-1">
                Password
              </label>
              <TextInput
                type="password"
                name="exigoDbPassword"
                placeholder="Database Password"
                defaultValue={exigoDbPassword}
              />
            </div>

            <div>
              <label className="block text-sm font-medium text-gray-700 mb-1">
                Database Name
              </label>
              <TextInput
                type="text"
                name="exigoDbName"
                placeholder="Database Name"
                defaultValue={exigoDbName}
              />
            </div>
          </div>
        </div>

        <div className="flex justify-between gap-3">
          <ConnectionStatusButton status={connectionStatus} />

          <div className="flex justify-end gap-3">
            <button
              type="button"
              onClick={handleTestConnection}
              className="px-4 py-2 border border-gray-300 rounded-md shadow-sm text-sm font-medium text-gray-700 bg-white hover:bg-gray-50 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-blue-500"
            >
              Test Connection
            </button>
            <button
              type="submit"
              className="px-4 py-2 bg-gray-900 hover:bg-gray-800 text-white text-sm font-medium rounded-md focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-blue-500 transition-colors"
            >
              Save
            </button>
          </div>
        </div>
      </form>
    </div>
  );
};

export default ConfigurationForm;