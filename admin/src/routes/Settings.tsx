import { useState } from 'react';
import { api } from '@/api/client';
import { MANAGEMENT_API_ROUTES } from '@/managementApiRoutes';
import styles from './Settings.module.css';

function methodBadgeClass(method: string): string {
  if (method === 'GET' || method === 'HEAD') return 'badge-green';
  if (method === 'DELETE') return 'badge-red';
  if (method === 'PUT') return 'badge-yellow';
  return 'badge-purple';
}

export default function Settings() {
  const [reloading, setReloading] = useState(false);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);

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
    <div className={styles.page}>
      {msg && (
        <div className={msg.ok ? 'success-banner' : 'error-banner'}>
          <i className={`fas ${msg.ok ? 'fa-check-circle' : 'fa-exclamation-circle'}`} />
          {msg.text}
        </div>
      )}

      <div className="card">
        <h2 style={{ marginBottom: 12 }}>Hot Reload</h2>
        <button className="btn btn-primary" type="button" onClick={() => void reload()} disabled={reloading}>
          {reloading ? (
            <>
              <span className="spinner" style={{ width: 14, height: 14 }} /> Reloading…
            </>
          ) : (
            <>
              <i className="fas fa-sync-alt" /> Reload Config
            </>
          )}
        </button>
      </div>

      <div className="card">
        <h2 style={{ marginBottom: 12 }}>Management API</h2>
        <div className={styles.tableWrap}>
          <table className={styles.table}>
            <thead>
              <tr>
                <th>Method</th>
                <th>Path</th>
                <th>Purpose</th>
              </tr>
            </thead>
            <tbody>
              {MANAGEMENT_API_ROUTES.map(({ method, path, purpose }) => (
                <tr key={`${method}-${path}`}>
                  <td>
                    <span className={`badge ${methodBadgeClass(method)}`}>{method}</span>
                  </td>
                  <td className={styles.pathCell}>{path}</td>
                  <td className={styles.descCell}>{purpose}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>
    </div>
  );
}
