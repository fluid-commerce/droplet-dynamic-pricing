import React from 'react';

type ConnectionStatus = 'default' | 'connecting' | 'connected' | 'error';

interface ConnectionStatusButtonProps {
  status: ConnectionStatus;
  disabled?: boolean;
}

const ConnectionStatusButton: React.FC<ConnectionStatusButtonProps> = ({ 
  status, 
  disabled = false 
}) => {
  const baseClasses = 'px-4 py-2 border rounded-md shadow-sm text-sm font-medium focus:outline-none focus:ring-2 focus:ring-offset-2';

  const getStatusConfig = () => {
    switch (status) {
      case 'connecting':
        return {
          text: 'Establishing Connection',
          className: `${baseClasses} border-blue-300 text-blue-700 bg-blue-50 hover:bg-blue-100 focus:ring-blue-500`
        };
      case 'connected':
        return {
          text: 'Connected',
          className: `${baseClasses} border-green-300 text-green-700 bg-green-50 hover:bg-green-100 focus:ring-green-500`
        };
      case 'error':
        return {
          text: 'Not Connected',
          className: `${baseClasses} border-red-300 text-red-700 bg-red-50 hover:bg-red-100 focus:ring-red-500`
        };
      default:
        return {
          text: 'Connection Status',
          className: `${baseClasses} border-gray-300 text-gray-700 bg-white hover:bg-gray-50 focus:ring-blue-500`
        };
    }
  };

  const config = getStatusConfig();

  return (
    <button
      type="button"
      disabled={disabled || status === 'connecting'}
      className={config.className}
    >
      {config.text}
    </button>
  );
};

export default ConnectionStatusButton;