import React, { useEffect, useState } from 'react';
import { Plus, RefreshCw, AlertCircle, Zap, Calendar } from 'lucide-react';
import { getCertificates, requestCertificate } from '../api/client';

function Certificates() {
  const [certs, setCerts] = useState(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);
  const [showForm, setShowForm] = useState(false);
  const [domains, setDomains] = useState('');
  const [submitting, setSubmitting] = useState(false);

  useEffect(() => {
    fetchCertificates();
  }, []);

  const fetchCertificates = async () => {
    try {
      setLoading(true);
      const data = await getCertificates();
      setCerts(data);
    } catch (err) {
      setError(err.message);
    } finally {
      setLoading(false);
    }
  };

  const handleSubmit = async (e) => {
    e.preventDefault();
    if (!domains.trim()) {
      setError('Please enter at least one domain');
      return;
    }

    try {
      setSubmitting(true);
      const domainList = domains.split(',').map((d) => d.trim()).filter((d) => d);
      await requestCertificate(domainList);
      setDomains('');
      setShowForm(false);
      setError(null);
      await fetchCertificates();
    } catch (err) {
      setError(err.message);
    } finally {
      setSubmitting(false);
    }
  };

  if (loading) {
    return (
      <div className="flex items-center justify-center h-96">
        <Zap className="animate-spin" size={32} />
      </div>
    );
  }

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-3xl font-bold text-gray-900">SSL/TLS Certificates</h1>
          <p className="text-gray-600 mt-2">Manage certificates and ACME automation</p>
        </div>
        <div className="flex gap-4">
          <button
            onClick={fetchCertificates}
            className="flex items-center gap-2 bg-gray-200 hover:bg-gray-300 text-gray-800 px-4 py-2 rounded-lg transition"
          >
            <RefreshCw size={20} />
            Refresh
          </button>
          <button
            onClick={() => setShowForm(!showForm)}
            className="flex items-center gap-2 bg-blue-600 hover:bg-blue-700 text-white px-4 py-2 rounded-lg transition"
          >
            <Plus size={20} />
            Request Certificate
          </button>
        </div>
      </div>

      {error && (
        <div className="bg-red-50 border border-red-200 rounded-lg p-4 flex items-start gap-4">
          <AlertCircle className="text-red-600 flex-shrink-0" size={24} />
          <div className="flex-1">
            <h3 className="font-semibold text-red-800">Error</h3>
            <p className="text-red-700 text-sm mt-1">{error}</p>
          </div>
        </div>
      )}

      {/* Request Form */}
      {showForm && (
        <div className="bg-white rounded-lg shadow p-6">
          <h2 className="text-xl font-semibold text-gray-900 mb-4">Request New Certificate</h2>
          <form onSubmit={handleSubmit} className="space-y-4">
            <div>
              <label className="block text-sm font-medium text-gray-700 mb-2">
                Domains (comma-separated) *
              </label>
              <textarea
                placeholder="example.com, www.example.com, api.example.com"
                value={domains}
                onChange={(e) => setDomains(e.target.value)}
                rows="4"
                className="w-full px-4 py-2 border border-gray-300 rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500 font-mono text-sm"
              />
              <p className="text-xs text-gray-500 mt-2">
                Enter each domain on a separate line or separated by commas
              </p>
            </div>
            <div className="bg-blue-50 border border-blue-200 rounded-lg p-4">
              <p className="text-sm text-blue-800">
                <strong>Note:</strong> The certificate will be automatically renewed 30 days before expiry.
                ACME must be enabled in settings.
              </p>
            </div>
            <div className="flex gap-4">
              <button
                type="submit"
                disabled={submitting}
                className="px-4 py-2 bg-blue-600 hover:bg-blue-700 text-white rounded-lg transition disabled:opacity-50"
              >
                {submitting ? 'Requesting...' : 'Request Certificate'}
              </button>
              <button
                type="button"
                onClick={() => setShowForm(false)}
                className="px-4 py-2 bg-gray-200 hover:bg-gray-300 text-gray-800 rounded-lg transition"
              >
                Cancel
              </button>
            </div>
          </form>
        </div>
      )}

      {/* Certificates Overview */}
      <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
        <StatCard
          title="Total Certificates"
          value={certs?.total || 0}
          color="bg-blue-500"
        />
        <StatCard
          title="Expiring Soon"
          value={certs?.expiring_soon?.length || 0}
          color="bg-yellow-500"
        />
        <StatCard
          title="Recently Issued"
          value={certs?.issued?.length || 0}
          color="bg-green-500"
        />
      </div>

      {/* Expiring Soon */}
      {certs?.expiring_soon && certs.expiring_soon.length > 0 && (
        <div className="bg-yellow-50 border border-yellow-200 rounded-lg p-6">
          <h2 className="text-lg font-semibold text-yellow-900 flex items-center gap-2">
            <AlertCircle size={20} />
            Certificates Expiring Soon
          </h2>
          <div className="mt-4 space-y-3">
            {certs.expiring_soon.map((cert, idx) => (
              <div key={idx} className="flex items-center justify-between bg-white rounded p-4">
                <div>
                  <p className="font-medium text-gray-900">{cert.domain || cert}</p>
                  <p className="text-sm text-gray-600 flex items-center gap-2 mt-1">
                    <Calendar size={14} />
                    Expires {cert.expiry || 'soon'}
                  </p>
                </div>
                <button className="px-4 py-2 bg-yellow-600 hover:bg-yellow-700 text-white text-sm rounded transition">
                  Renew Now
                </button>
              </div>
            ))}
          </div>
        </div>
      )}

      {/* All Certificates */}
      <div className="bg-white rounded-lg shadow overflow-hidden">
        <div className="p-6 border-b">
          <h2 className="text-xl font-semibold text-gray-900">All Certificates</h2>
        </div>
        {certs?.issued && certs.issued.length > 0 ? (
          <div className="divide-y">
            {certs.issued.map((cert, idx) => (
              <div key={idx} className="p-6 hover:bg-gray-50">
                <div className="flex items-start justify-between">
                  <div>
                    <p className="font-semibold text-gray-900">{cert.domain || cert}</p>
                    <p className="text-sm text-gray-600 mt-2">
                      Issued: {cert.issued_at || new Date().toLocaleDateString()}
                    </p>
                    <p className="text-sm text-gray-600">
                      Expires: {cert.expires_at || 'Unknown'}
                    </p>
                  </div>
                  <span className="px-3 py-1 bg-green-100 text-green-800 text-xs rounded-full">
                    Valid
                  </span>
                </div>
              </div>
            ))}
          </div>
        ) : (
          <div className="p-6 text-center text-gray-500">
            <p>No certificates issued yet.</p>
          </div>
        )}
      </div>

      {/* ACME Info */}
      <div className="bg-blue-50 border border-blue-200 rounded-lg p-6">
        <h3 className="font-semibold text-blue-900 mb-3">Automatic Certificate Management</h3>
        <ul className="space-y-2 text-sm text-blue-800">
          <li>✓ Automatic issuance for configured domains</li>
          <li>✓ Renewal 30 days before expiry</li>
          <li>✓ HTTP-01, DNS-01, and TLS-ALPN-01 challenge support</li>
          <li>✓ Let's Encrypt integration</li>
        </ul>
        <p className="mt-4 text-xs text-blue-700">
          Configure ACME settings in the <a href="/settings" className="underline font-semibold">Settings page</a>
        </p>
      </div>
    </div>
  );
}

function StatCard({ title, value, color }) {
  return (
    <div className="bg-white rounded-lg shadow p-6">
      <div className="flex items-start justify-between">
        <div>
          <p className="text-gray-600 text-sm font-medium">{title}</p>
          <p className="text-3xl font-bold text-gray-900 mt-2">{value}</p>
        </div>
        <div className={`${color} p-3 rounded-lg`}>
          <Calendar size={24} className="text-white" />
        </div>
      </div>
    </div>
  );
}

export default Certificates;
