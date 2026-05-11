import { useEffect, useState, useCallback } from 'react';
import { Link } from 'react-router-dom';
import { api, type HealthReport, type ProxyConfig } from '@/api/client';
import styles from './Dashboard.module.css';

export default function Dashboard() {
  const [config, setConfig] = useState<ProxyConfig | null>(null);
  const [health, setHealth] = useState<HealthReport | null>(null);
  const [error, setError]   = useState<string | null>(null);
  const [loading, setLoading] = useState(true);

  const load = useCallback(async () => {
    try {
      const [c, h] = await Promise.all([api.config(), api.health()]);
      setConfig(c);
      setHealth(h);
      setError(null);
    } catch (e: unknown) {
      setError(String(e));
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => { load(); }, [load]);

  const totalHealthy = health?.backends.reduce((s, b) => s + b.healthy, 0) ?? 0;
  const totalUpstreams = health?.backends.reduce((s, b) => s + b.total, 0) ?? 0;

  return (
    <div>
      <div className="page-header">
        <div className="page-title">
          <i className="fas fa-home" />
          <h1>Dashboard</h1>
        </div>
        <button className="btn btn-ghost btn-sm" onClick={load}>
          <i className="fas fa-sync-alt" /> Refresh
        </button>
      </div>

      {error && <div className="error-banner"><i className="fas fa-exclamation-circle" />{error}</div>}

      {loading ? (
        <div style={{ display: 'flex', justifyContent: 'center', padding: '60px' }}>
          <div className="spinner" />
        </div>
      ) : (
        <>
          <div className={styles.grid}>
            <div className={`card ${styles.statCard}`}>
              <div className={`${styles.statIcon} ${styles.purple}`}>
                <i className="fas fa-globe" />
              </div>
              <div className={styles.statValue}>{config?.sites?.length ?? 0}</div>
              <div className={styles.statLabel}>Sites</div>
            </div>
            <div className={`card ${styles.statCard}`}>
              <div className={`${styles.statIcon} ${styles.blue}`}>
                <i className="fas fa-server" />
              </div>
              <div className={styles.statValue}>{config?.backends?.length ?? 0}</div>
              <div className={styles.statLabel}>Backends</div>
            </div>
            <div className={`card ${styles.statCard}`}>
              <div className={`${styles.statIcon} ${styles.green}`}>
                <i className="fas fa-heartbeat" />
              </div>
              <div className={styles.statValue}>{totalHealthy}<span style={{ fontSize: '1rem', color: 'var(--color-muted)' }}>/{totalUpstreams}</span></div>
              <div className={styles.statLabel}>Healthy Upstreams</div>
            </div>
            <div className={`card ${styles.statCard}`}>
              <div className={`${styles.statIcon} ${styles.yellow}`}>
                <i className="fas fa-plug" />
              </div>
              <div className={styles.statValue}>{config?.http_port ?? '—'}</div>
              <div className={styles.statLabel}>HTTP Port</div>
            </div>
          </div>

          {/* Sites quick list */}
          <div className={styles.section}>
            <div className={styles.sectionTitle}>Sites</div>
            <div className="card" style={{ padding: 0 }}>
              {config?.sites.length === 0 ? (
                <div style={{ padding: '20px', color: 'var(--color-muted)', textAlign: 'center' }}>
                  No sites configured. <Link to="/sites">Add one →</Link>
                </div>
              ) : (
                <table>
                  <thead>
                    <tr>
                      <th>Host</th>
                      <th>Backend</th>
                      <th>Routes</th>
                    </tr>
                  </thead>
                  <tbody>
                    {config?.sites.map(s => (
                      <tr key={s.host}>
                        <td className="mono" style={{ color: 'var(--color-text)' }}>
                          <Link to={`/sites/${encodeURIComponent(s.host)}`}>{s.host}</Link>
                        </td>
                        <td>{s.backend}</td>
                        <td><span className="badge badge-purple">{s.routes.length}</span></td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              )}
            </div>
          </div>
        </>
      )}
    </div>
  );
}
