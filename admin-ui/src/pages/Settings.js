import React, { useState } from 'react';
import { AlertCircle, CheckCircle, Save } from 'lucide-react';

function Settings() {
  const [settings, setSettings] = useState({
    acme_enabled: true,
    acme_provider: 'https://acme-v02.api.letsencrypt.org/directory',
    acme_email: 'admin@example.com',
    listen_addr: '0.0.0.0',
    listen_port_h2: 443,
    listen_port_h3: 443,
    admin_port: 8080,
    compression_methods: ['brotli', 'zstd', 'gzip'],
  });

  const [saved, setSaved] = useState(false);
  const [error, setError] = useState(null);

  const handleChange = (key, value) => {
    setSettings((prev) => ({
      ...prev,
      [key]: value,
    }));
    setSaved(false);
  };

  const handleSave = async () => {
    try {
      // TODO: Implement API call to save settings
      console.log('Saving settings:', settings);
      setSaved(true);
      setTimeout(() => setSaved(false), 3000);
    } catch (err) {
      setError(err.message);
    }
  };

  return (
    <div className="space-y-6 max-w-2xl">
      <div>
        <h1 className="text-3xl font-bold text-gray-900">Settings</h1>
        <p className="text-gray-600 mt-2">Configure the reverse proxy and ACME settings</p>
      </div>

      {error && (
        <div className="bg-red-50 border border-red-200 rounded-lg p-4 flex items-start gap-4">
          <AlertCircle className="text-red-600 flex-shrink-0" size={24} />
          <div>
            <h3 className="font-semibold text-red-800">Error</h3>
            <p className="text-red-700 text-sm mt-1">{error}</p>
          </div>
        </div>
      )}

      {saved && (
        <div className="bg-green-50 border border-green-200 rounded-lg p-4 flex items-start gap-4">
          <CheckCircle className="text-green-600 flex-shrink-0" size={24} />
          <div>
            <h3 className="font-semibold text-green-800">Settings saved</h3>
            <p className="text-green-700 text-sm mt-1">Your changes have been applied successfully</p>
          </div>
        </div>
      )}

      {/* ACME Settings */}
      <div className="bg-white rounded-lg shadow p-6">
        <h2 className="text-xl font-semibold text-gray-900 mb-6">ACME Configuration</h2>

        <div className="space-y-4">
          <div>
            <label className="flex items-center gap-3">
              <input
                type="checkbox"
                checked={settings.acme_enabled}
                onChange={(e) => handleChange('acme_enabled', e.target.checked)}
                className="w-4 h-4"
              />
              <span className="font-medium text-gray-700">Enable Automatic ACME (Let's Encrypt)</span>
            </label>
          </div>

          {settings.acme_enabled && (
            <>
              <div>
                <label className="block text-sm font-medium text-gray-700 mb-2">
                  ACME Provider
                </label>
                <input
                  type="text"
                  value={settings.acme_provider}
                  onChange={(e) => handleChange('acme_provider', e.target.value)}
                  className="w-full px-4 py-2 border border-gray-300 rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500"
                />
                <p className="text-xs text-gray-500 mt-2">
                  Default: Let's Encrypt (production environment)
                </p>
              </div>

              <div>
                <label className="block text-sm font-medium text-gray-700 mb-2">
                  ACME Account Email
                </label>
                <input
                  type="email"
                  value={settings.acme_email}
                  onChange={(e) => handleChange('acme_email', e.target.value)}
                  className="w-full px-4 py-2 border border-gray-300 rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500"
                />
                <p className="text-xs text-gray-500 mt-2">
                  Email address for ACME certificate notifications
                </p>
              </div>
            </>
          )}
        </div>
      </div>

      {/* Network Settings */}
      <div className="bg-white rounded-lg shadow p-6">
        <h2 className="text-xl font-semibold text-gray-900 mb-6">Network Configuration</h2>

        <div className="space-y-4">
          <div>
            <label className="block text-sm font-medium text-gray-700 mb-2">
              Listen Address
            </label>
            <input
              type="text"
              value={settings.listen_addr}
              onChange={(e) => handleChange('listen_addr', e.target.value)}
              className="w-full px-4 py-2 border border-gray-300 rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500"
            />
          </div>

          <div className="grid grid-cols-2 gap-4">
            <div>
              <label className="block text-sm font-medium text-gray-700 mb-2">
                HTTP/2 Port
              </label>
              <input
                type="number"
                value={settings.listen_port_h2}
                onChange={(e) => handleChange('listen_port_h2', parseInt(e.target.value))}
                className="w-full px-4 py-2 border border-gray-300 rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500"
              />
            </div>

            <div>
              <label className="block text-sm font-medium text-gray-700 mb-2">
                HTTP/3 Port
              </label>
              <input
                type="number"
                value={settings.listen_port_h3}
                onChange={(e) => handleChange('listen_port_h3', parseInt(e.target.value))}
                className="w-full px-4 py-2 border border-gray-300 rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500"
              />
            </div>
          </div>

          <div>
            <label className="block text-sm font-medium text-gray-700 mb-2">
              Admin Interface Port
            </label>
            <input
              type="number"
              value={settings.admin_port}
              onChange={(e) => handleChange('admin_port', parseInt(e.target.value))}
              disabled
              className="w-full px-4 py-2 border border-gray-300 rounded-lg bg-gray-50 cursor-not-allowed"
            />
            <p className="text-xs text-gray-500 mt-2">
              (Read-only - restart the service to change)
            </p>
          </div>
        </div>
      </div>

      {/* Compression Settings */}
      <div className="bg-white rounded-lg shadow p-6">
        <h2 className="text-xl font-semibold text-gray-900 mb-6">Compression</h2>

        <div className="space-y-3">
          <p className="text-sm text-gray-600 mb-4">Enabled compression methods:</p>
          {['brotli', 'zstd', 'gzip'].map((method) => (
            <label key={method} className="flex items-center gap-3">
              <input
                type="checkbox"
                checked={settings.compression_methods.includes(method)}
                onChange={(e) => {
                  const methods = e.target.checked
                    ? [...settings.compression_methods, method]
                    : settings.compression_methods.filter((m) => m !== method);
                  handleChange('compression_methods', methods);
                }}
                className="w-4 h-4"
              />
              <span className="font-medium text-gray-700 capitalize">
                {method}
                {method === 'brotli' && ' - Best compression ratio (high CPU)'}
                {method === 'zstd' && ' - Fast compression (balanced)'}
                {method === 'gzip' && ' - Wide compatibility (standard)'}
              </span>
            </label>
          ))}
        </div>
      </div>

      {/* Save Button */}
      <div className="flex gap-4 sticky bottom-6">
        <button
          onClick={handleSave}
          className="flex items-center gap-2 bg-blue-600 hover:bg-blue-700 text-white px-6 py-3 rounded-lg transition font-medium"
        >
          <Save size={20} />
          Save Settings
        </button>
        <button
          onClick={() => window.location.reload()}
          className="px-6 py-3 bg-gray-200 hover:bg-gray-300 text-gray-800 rounded-lg transition font-medium"
        >
          Reset
        </button>
      </div>

      {/* Information */}
      <div className="bg-blue-50 border border-blue-200 rounded-lg p-6">
        <h3 className="font-semibold text-blue-900 mb-3">Important Information</h3>
        <ul className="space-y-2 text-sm text-blue-800">
          <li>• Changes to network ports require a service restart</li>
          <li>• ACME requires valid domain DNS records pointing to your server</li>
          <li>• Brotli compression requires more CPU but provides better compression ratios</li>
          <li>• All certificates are stored securely on the server</li>
        </ul>
      </div>
    </div>
  );
}

export default Settings;
