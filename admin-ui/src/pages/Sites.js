import React, { useEffect, useState } from 'react';
import { Plus, Trash2, AlertCircle, CheckCircle, Zap } from 'lucide-react';
import { getUpstreams, addUpstream, removeUpstream } from '../api/client';

function Sites() {
  const [upstreams, setUpstreams] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);
  const [showForm, setShowForm] = useState(false);
  const [formData, setFormData] = useState({
    name: '',
    target: '',
    health_check: '',
    weight: 1,
  });
  const [submitting, setSubmitting] = useState(false);

  useEffect(() => {
    fetchUpstreams();
  }, []);

  const fetchUpstreams = async () => {
    try {
      setLoading(true);
      const data = await getUpstreams();
      setUpstreams(data);
    } catch (err) {
      setError(err.message);
    } finally {
      setLoading(false);
    }
  };

  const handleSubmit = async (e) => {
    e.preventDefault();
    if (!formData.name || !formData.target) {
      setError('Name and target are required');
      return;
    }

    try {
      setSubmitting(true);
      await addUpstream(formData);
      setFormData({ name: '', target: '', health_check: '', weight: 1 });
      setShowForm(false);
      setError(null);
      await fetchUpstreams();
    } catch (err) {
      setError(err.message);
    } finally {
      setSubmitting(false);
    }
  };

  const handleDelete = async (host) => {
    if (!window.confirm(`Are you sure you want to remove ${host}?`)) return;

    try {
      await removeUpstream(host);
      await fetchUpstreams();
    } catch (err) {
      setError(err.message);
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
          <h1 className="text-3xl font-bold text-gray-900">Reverse Proxy Sites</h1>
          <p className="text-gray-600 mt-2">Manage upstream servers and routing</p>
        </div>
        <button
          onClick={() => setShowForm(!showForm)}
          className="flex items-center gap-2 bg-blue-600 hover:bg-blue-700 text-white px-4 py-2 rounded-lg transition"
        >
          <Plus size={20} />
          Add Site
        </button>
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

      {/* Add Form */}
      {showForm && (
        <div className="bg-white rounded-lg shadow p-6">
          <h2 className="text-xl font-semibold text-gray-900 mb-4">Add New Site</h2>
          <form onSubmit={handleSubmit} className="space-y-4">
            <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
              <div>
                <label className="block text-sm font-medium text-gray-700 mb-2">
                  Site Name *
                </label>
                <input
                  type="text"
                  placeholder="api.example.com"
                  value={formData.name}
                  onChange={(e) => setFormData({ ...formData, name: e.target.value })}
                  className="w-full px-4 py-2 border border-gray-300 rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500"
                />
              </div>
              <div>
                <label className="block text-sm font-medium text-gray-700 mb-2">
                  Target Upstream *
                </label>
                <input
                  type="text"
                  placeholder="192.168.1.100:8080"
                  value={formData.target}
                  onChange={(e) => setFormData({ ...formData, target: e.target.value })}
                  className="w-full px-4 py-2 border border-gray-300 rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500"
                />
              </div>
              <div>
                <label className="block text-sm font-medium text-gray-700 mb-2">
                  Health Check URL
                </label>
                <input
                  type="text"
                  placeholder="http://192.168.1.100:8080/health"
                  value={formData.health_check}
                  onChange={(e) => setFormData({ ...formData, health_check: e.target.value })}
                  className="w-full px-4 py-2 border border-gray-300 rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500"
                />
              </div>
              <div>
                <label className="block text-sm font-medium text-gray-700 mb-2">
                  Weight
                </label>
                <input
                  type="number"
                  min="1"
                  value={formData.weight}
                  onChange={(e) => setFormData({ ...formData, weight: parseInt(e.target.value) })}
                  className="w-full px-4 py-2 border border-gray-300 rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500"
                />
              </div>
            </div>
            <div className="flex gap-4">
              <button
                type="submit"
                disabled={submitting}
                className="px-4 py-2 bg-blue-600 hover:bg-blue-700 text-white rounded-lg transition disabled:opacity-50"
              >
                {submitting ? 'Adding...' : 'Add Site'}
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

      {/* Sites List */}
      <div className="bg-white rounded-lg shadow overflow-hidden">
        {upstreams.length === 0 ? (
          <div className="p-8 text-center text-gray-500">
            <p>No sites configured yet.</p>
          </div>
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full">
              <thead className="bg-gray-50 border-b">
                <tr>
                  <th className="px-6 py-3 text-left text-sm font-semibold text-gray-900">Site Name</th>
                  <th className="px-6 py-3 text-left text-sm font-semibold text-gray-900">Target</th>
                  <th className="px-6 py-3 text-left text-sm font-semibold text-gray-900">Weight</th>
                  <th className="px-6 py-3 text-left text-sm font-semibold text-gray-900">Status</th>
                  <th className="px-6 py-3 text-left text-sm font-semibold text-gray-900">Actions</th>
                </tr>
              </thead>
              <tbody className="divide-y">
                {upstreams.map((upstream, idx) => (
                  <tr key={idx} className="hover:bg-gray-50">
                    <td className="px-6 py-4 text-sm font-medium text-gray-900">
                      {upstream.host}
                    </td>
                    <td className="px-6 py-4 text-sm text-gray-600">
                      {typeof upstream.config === 'object'
                        ? upstream.config.target
                        : upstream.config}
                    </td>
                    <td className="px-6 py-4 text-sm text-gray-600">
                      {typeof upstream.config === 'object' && upstream.config.weight
                        ? upstream.config.weight
                        : 1}
                    </td>
                    <td className="px-6 py-4">
                      <span className="px-3 py-1 bg-green-100 text-green-800 text-xs rounded-full flex items-center gap-1 w-fit">
                        <CheckCircle size={14} />
                        Active
                      </span>
                    </td>
                    <td className="px-6 py-4">
                      <button
                        onClick={() => handleDelete(upstream.host)}
                        className="text-red-600 hover:text-red-800 transition"
                      >
                        <Trash2 size={18} />
                      </button>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>
    </div>
  );
}

export default Sites;
