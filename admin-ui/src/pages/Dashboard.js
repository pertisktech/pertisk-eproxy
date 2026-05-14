import React, { useEffect, useState } from 'react';
import { AlertCircle, CheckCircle, Shield, Zap, Globe } from 'lucide-react';
import { getStatus, getUpstreams, getCertificates } from '../api/client';

function Dashboard() {
  const [status, setStatus] = useState(null);
  const [upstreams, setUpstreams] = useState([]);
  const [certs, setCerts] = useState(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);

  useEffect(() => {
    const fetchData = async () => {
      try {
        setLoading(true);
        const [statusData, upstreamsData, certsData] = await Promise.all([
          getStatus(),
          getUpstreams(),
          getCertificates(),
        ]);
        setStatus(statusData);
        setUpstreams(upstreamsData);
        setCerts(certsData);
      } catch (err) {
        setError(err.message);
        console.error('Error fetching dashboard data:', err);
      } finally {
        setLoading(false);
      }
    };

    fetchData();
    const interval = setInterval(fetchData, 10000); // Refresh every 10 seconds
    return () => clearInterval(interval);
  }, []);

  if (loading) {
    return (
      <div className="flex items-center justify-center h-96">
        <div className="text-center">
          <Zap className="animate-spin mx-auto mb-4" size={32} />
          <p className="text-gray-600">Loading dashboard...</p>
        </div>
      </div>
    );
  }

  if (error) {
    return (
      <div className="bg-red-50 border border-red-200 rounded-lg p-4 flex items-start gap-4">
        <AlertCircle className="text-red-600 flex-shrink-0" size={24} />
        <div>
          <h3 className="font-semibold text-red-800">Connection Error</h3>
          <p className="text-red-700 text-sm mt-1">
            Unable to connect to the API. Make sure the eProxy server is running on localhost:8080
          </p>
          <p className="text-red-600 text-xs mt-2">{error}</p>
        </div>
      </div>
    );
  }

  return (
    <div className="space-y-6">
      {/* Header */}
      <div>
        <h1 className="text-3xl font-bold text-gray-900">Dashboard</h1>
        <p className="text-gray-600 mt-2">System overview and statistics</p>
      </div>

      {/* Stats Grid */}
      <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-4">
        <StatCard
          icon={Globe}
          title="Active Sites"
          value={upstreams.length}
          color="bg-blue-500"
        />
        <StatCard
          icon={Shield}
          title="Certificates"
          value={certs?.total || 0}
          color="bg-green-500"
        />
        <StatCard
          icon={Zap}
          title="Compression Methods"
          value={status?.compression_methods?.length || 0}
          color="bg-purple-500"
        />
        <StatCard
          icon={CheckCircle}
          title="Status"
          value="Healthy"
          color="bg-yellow-500"
        />
      </div>

      {/* Upstreams List */}
      <div className="bg-white rounded-lg shadow">
        <div className="p-6 border-b">
          <h2 className="text-xl font-semibold text-gray-900">Active Upstreams</h2>
        </div>
        <div className="divide-y">
          {upstreams.length === 0 ? (
            <div className="p-6 text-center text-gray-500">
              <p>No upstreams configured. <a href="/sites" className="text-blue-600 hover:underline">Add one</a></p>
            </div>
          ) : (
            upstreams.map((upstream, idx) => (
              <div key={idx} className="p-6 flex items-center justify-between hover:bg-gray-50">
                <div>
                  <p className="font-semibold text-gray-900">{upstream.host}</p>
                  <p className="text-sm text-gray-600 mt-1">
                    {typeof upstream.config === 'object' 
                      ? upstream.config.target 
                      : upstream.config}
                  </p>
                </div>
                <div className="flex items-center gap-3">
                  <span className="px-3 py-1 bg-green-100 text-green-800 text-xs rounded-full">
                    Active
                  </span>
                </div>
              </div>
            ))
          )}
        </div>
      </div>

      {/* Certificates Status */}
      {certs && (
        <div className="bg-white rounded-lg shadow">
          <div className="p-6 border-b">
            <h2 className="text-xl font-semibold text-gray-900">Certificate Status</h2>
          </div>
          <div className="p-6">
            {certs.expiring_soon && certs.expiring_soon.length > 0 && (
              <div className="mb-4 p-4 bg-yellow-50 border border-yellow-200 rounded-lg">
                <p className="text-yellow-800 font-semibold">Certificates expiring soon</p>
                <ul className="mt-2 text-sm text-yellow-700">
                  {certs.expiring_soon.map((cert, idx) => (
                    <li key={idx}>• {cert}</li>
                  ))}
                </ul>
              </div>
            )}
            <p className="text-gray-600">
              Total certificates: <span className="font-semibold">{certs.total || 0}</span>
            </p>
          </div>
        </div>
      )}
    </div>
  );
}

function StatCard({ icon: Icon, title, value, color }) {
  return (
    <div className="bg-white rounded-lg shadow p-6">
      <div className="flex items-start justify-between">
        <div>
          <p className="text-gray-600 text-sm font-medium">{title}</p>
          <p className="text-3xl font-bold text-gray-900 mt-2">{value}</p>
        </div>
        <div className={`${color} p-3 rounded-lg`}>
          <Icon size={24} className="text-white" />
        </div>
      </div>
    </div>
  );
}

export default Dashboard;
