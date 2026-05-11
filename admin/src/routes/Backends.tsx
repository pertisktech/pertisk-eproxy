import { useEffect, useState, useCallback } from 'react';
import { api, type Backend, type BackendStatus, type LbAlgorithm, type Upstream } from '@/api/client';
import styles from './Backends.module.css';

const EMPTY_UP: Upstream = { addr: '', weight: 1 };

function BackendModal({ onClose, onSaved }: { onClose: () => void; onSaved: () => void }) {
  const [name, setName]           = useState('');
  const [algo, setAlgo]           = useState<LbAlgorithm>('round_robin');
  const [upstreams, setUpstreams] = useState<Upstream[]>([{ ...EMPTY_UP }]);
  const [healthPath, setHealthPath] = useState('/health');
  const [healthSecs, setHealthSecs] = useState(30);
  const [saving, setSaving]       = useState(false);
  const [error, setError]         = useState<string | null>(null);

  const updateUp = (i: number, key: keyof Upstream, value: string | number) =>
    setUpstreams(us => us.map((u, idx) => idx === i ? { ...u, [key]: value } : u));

  const save = async () => {
    if (!name.trim()) { setError('Name is required'); return; }
    if (upstreams.some(u => !u.addr.trim())) { setError('All upstream addresses are required'); return; }
    setSaving(true);
    try {
      const backend: Backend = {
        name: name.trim(), algorithm: algo,
        upstreams: upstreams.map(u => ({ addr: u.addr.trim(), weight: Number(u.weight) || 1 })),
        health_path: healthPath || null,
        health_interval_secs: healthSecs,
      };
      await api.addBackend(backend);
      onSaved(); onClose();
    } catch (e: unknown) { setError(String(e)); }
    finally { setSaving(false); }
  };

  return (
    <div className="modal-overlay" onClick={e => e.target === e.currentTarget && onClose()}>
      <div className="modal">
        <div className="modal-header">
          <div className="modal-title"><i className="fas fa-server" /> Add Backend</div>
          <button className="modal-close btn" onClick={onClose}><i className="fas fa-times" /></button>
        </div>
        {error && <div className="error-banner"><i className="fas fa-exclamation-circle" />{error}</div>}

        <div className="form-row">
          <div className="form-group">
            <label>Name</label>
            <input value={name} onChange={e => setName(e.target.value)} placeholder="my-backend" />
          </div>
          <div className="form-group">
            <label>Algorithm</label>
            <select value={algo} onChange={e => setAlgo(e.target.value as LbAlgorithm)}>
              <option value="round_robin">Round Robin</option>
              <option value="least_connections">Least Connections</option>
              <option value="ip_hash">IP Hash</option>
            </select>
          </div>
        </div>

        <div className="form-group">
          <label>Upstreams</label>
          <div className={styles.upstreamList}>
            {upstreams.map((u, i) => (
              <div key={i} className={styles.upstreamRow}>
                <input
                  value={u.addr}
                  onChange={e => updateUp(i, 'addr', e.target.value)}
                  placeholder="host:port"
                  className="mono"
                />
                <input
                  type="number" min={1}
                  value={u.weight}
                  onChange={e => updateUp(i, 'weight', parseInt(e.target.value) || 1)}
                  placeholder="weight"
                />
                <button
                  type="button"
                  className={styles.upstreamRemove}
                  onClick={() => setUpstreams(us => us.filter((_, idx) => idx !== i))}
                  title="Remove"
                >
                  <i className="fas fa-minus-circle" />
                </button>
              </div>
            ))}
          </div>
          <button type="button" className={styles.addBtn} onClick={() => setUpstreams(us => [...us, { ...EMPTY_UP }])}>
            <i className="fas fa-plus" /> Add upstream
          </button>
        </div>

        <div className="form-row">
          <div className="form-group">
            <label>Health Check Path</label>
            <input value={healthPath} onChange={e => setHealthPath(e.target.value)} placeholder="/health" className="mono" />
          </div>
          <div className="form-group">
            <label>Interval (secs)</label>
            <input type="number" min={5} value={healthSecs} onChange={e => setHealthSecs(parseInt(e.target.value) || 30)} />
          </div>
        </div>

        <div className="modal-footer">
          <button className="btn btn-ghost" onClick={onClose}>Cancel</button>
          <button className="btn btn-primary" onClick={save} disabled={saving}>
            {saving ? <><span className="spinner" style={{ width: 14, height: 14 }} /> Saving…</> : 'Save Backend'}
          </button>
        </div>
      </div>
    </div>
  );
}

function algoLabel(a: LbAlgorithm) {
  return { round_robin: 'Round Robin', least_connections: 'Least Conns', ip_hash: 'IP Hash' }[a] ?? a;
}

export default function Backends() {
  const [backends, setBackends]   = useState<Backend[]>([]);
  const [statuses, setStatuses]   = useState<Record<string, BackendStatus>>({});
  const [loading, setLoading]     = useState(true);
  const [error, setError]         = useState<string | null>(null);
  const [showAdd, setShowAdd]     = useState(false);
  const [deleting, setDeleting]   = useState<string | null>(null);

  const load = useCallback(async () => {
    try {
      const bs = await api.backends();
      setBackends(bs);
      const statusMap: Record<string, BackendStatus> = {};
      await Promise.all(bs.map(async b => {
        try { statusMap[b.name] = await api.backendStatus(b.name); } catch { /* ignore */ }
      }));
      setStatuses(statusMap);
      setError(null);
    } catch (e: unknown) { setError(String(e)); }
    finally { setLoading(false); }
  }, []);

  useEffect(() => { load(); }, [load]);

  const deleteBackend = async (name: string) => {
    if (!confirm(`Delete backend "${name}"?`)) return;
    setDeleting(name);
    try { await api.deleteBackend(name); await load(); }
    catch (e: unknown) { setError(String(e)); }
    finally { setDeleting(null); }
  };

  return (
    <div>
      <div className="page-header">
        <div className="page-title">
          <i className="fas fa-server" />
          <h1>Backends</h1>
        </div>
        <button className="btn btn-primary" onClick={() => setShowAdd(true)}>
          <i className="fas fa-plus" /> Add Backend
        </button>
      </div>

      {error && <div className="error-banner"><i className="fas fa-exclamation-circle" />{error}</div>}

      {loading ? (
        <div style={{ display: 'flex', justifyContent: 'center', padding: '60px' }}>
          <div className="spinner" />
        </div>
      ) : (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 16 }}>
          {backends.length === 0 ? (
            <div className="card" style={{ textAlign: 'center', color: 'var(--color-muted)' }}>
              No backends yet. Click <strong>Add Backend</strong> to get started.
            </div>
          ) : (
            backends.map(b => {
              const st = statuses[b.name];
              return (
                <div key={b.name} className="card">
                  <div style={{ display: 'flex', alignItems: 'center', gap: 12, marginBottom: 14 }}>
                    <div style={{ flex: 1 }}>
                      <div style={{ fontWeight: 700, color: 'var(--color-text)', marginBottom: 4 }}>{b.name}</div>
                      <div style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
                        <span className="badge badge-purple">{algoLabel(b.algorithm)}</span>
                        {b.health_path && (
                          <span className="mono" style={{ fontSize: 11, color: 'var(--color-muted)' }}>
                            health: {b.health_path} every {b.health_interval_secs}s
                          </span>
                        )}
                      </div>
                    </div>
                    <button
                      className="btn btn-danger btn-sm"
                      onClick={() => deleteBackend(b.name)}
                      disabled={deleting === b.name}
                    >
                      {deleting === b.name
                        ? <span className="spinner" style={{ width: 12, height: 12 }} />
                        : <><i className="fas fa-trash" /> Delete</>}
                    </button>
                  </div>

                  <table>
                    <thead>
                      <tr>
                        <th>Upstream</th>
                        <th>Weight</th>
                        <th>Status</th>
                        <th>Conns</th>
                      </tr>
                    </thead>
                    <tbody>
                      {(st?.upstreams ?? b.upstreams.map(u => ({ ...u, healthy: true, conns: 0 }))).map((u, i) => (
                        <tr key={i}>
                          <td className="mono" style={{ color: 'var(--color-text)' }}>{u.addr}</td>
                          <td>{u.weight}</td>
                          <td>
                            {'healthy' in u
                              ? <span className={`badge ${u.healthy ? 'badge-green' : 'badge-red'}`}>
                                  {u.healthy ? 'healthy' : 'down'}
                                </span>
                              : <span className="badge badge-yellow">unknown</span>
                            }
                          </td>
                          <td>{'conns' in u ? u.conns : '—'}</td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              );
            })
          )}
        </div>
      )}

      {showAdd && <BackendModal onClose={() => setShowAdd(false)} onSaved={load} />}
    </div>
  );
}
