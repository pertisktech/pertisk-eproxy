import { useState } from 'react';
import { api } from '@/api/client';

export default function Settings() {
  const [reloading, setReloading] = useState(false);
  const [msg, setMsg]             = useState<{ ok: boolean; text: string } | null>(null);

  const reload = async () => {
    setReloading(true);
    setMsg(null);
    try {
      await api.reload();
      setMsg({ ok: true, text: 'Config reloaded successfully.' });
    } catch (e: unknown) {
      setMsg({ ok: false, text: String(e) });
    } finally {
      setReloading(false);
    }
  };

  return (
    <div>
      {msg && (
        <div className={msg.ok ? 'success-banner' : 'error-banner'}>
          <i className={`fas ${msg.ok ? 'fa-check-circle' : 'fa-exclamation-circle'}`} />
          {msg.text}
        </div>
      )}

      <div className="card" style={{ maxWidth: 560 }}>
        <h2 style={{ marginBottom: 8 }}>Hot Reload</h2>
        <p style={{ color: 'var(--color-text-secondary)', marginBottom: 20, fontSize: 13 }}>
          Reload <code className="mono">config/proxy.json</code> from disk without restarting the proxy.
          All running connections are preserved.
        </p>
        <button className="btn btn-primary" onClick={reload} disabled={reloading}>
          {reloading
            ? <><span className="spinner" style={{ width: 14, height: 14 }} /> Reloading…</>
            : <><i className="fas fa-sync-alt" /> Reload Config</>}
        </button>
      </div>

      <div className="card" style={{ maxWidth: 560, marginTop: 16 }}>
        <h2 style={{ marginBottom: 8 }}>Management API</h2>
        <p style={{ color: 'var(--color-text-secondary)', fontSize: 13, marginBottom: 12 }}>
          The management API is available at <code className="mono">http://127.0.0.1:9080/api</code>.
        </p>
        <table>
          <tbody>
            {[
              ['GET',    '/api/config',           'Full proxy config'],
              ['PUT',    '/api/config',            'Replace proxy config'],
              ['GET',    '/api/sites',             'List sites'],
              ['POST',   '/api/sites',             'Add site'],
              ['DELETE', '/api/sites/:host',       'Remove site'],
              ['GET',    '/api/health',            'Health report'],
              ['GET',    '/api/metrics',           'Prometheus metrics'],
              ['POST',   '/api/reload',            'Hot-reload from file'],
            ].map(([method, path, desc]) => (
              <tr key={path}>
                <td><span className={`badge ${method === 'GET' ? 'badge-green' : method === 'DELETE' ? 'badge-red' : 'badge-purple'}`}>{method}</span></td>
                <td className="mono" style={{ color: 'var(--color-text)' }}>{path}</td>
                <td style={{ color: 'var(--color-muted)' }}>{desc}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}
