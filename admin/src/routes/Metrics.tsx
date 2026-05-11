import { useEffect, useState, useCallback } from 'react';
import { api } from '@/api/client';

interface MetricLine {
  help: string;
  type: string;
  lines: string[];
}

function parseMetrics(text: string): MetricLine[] {
  const groups: MetricLine[] = [];
  let current: MetricLine | null = null;
  for (const raw of text.split('\n')) {
    const line = raw.trim();
    if (line.startsWith('# HELP ')) {
      if (current) groups.push(current);
      current = { help: line.slice(7), type: '', lines: [] };
    } else if (line.startsWith('# TYPE ') && current) {
      current.type = line.split(' ')[3] ?? '';
    } else if (line && current) {
      current.lines.push(line);
    }
  }
  if (current) groups.push(current);
  return groups.filter(g => g.lines.length > 0);
}

export default function Metrics() {
  const [raw, setRaw]       = useState<string>('');
  const [groups, setGroups] = useState<MetricLine[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError]   = useState<string | null>(null);
  const [view, setView]     = useState<'parsed' | 'raw'>('parsed');

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const text = await api.metricsText();
      setRaw(text);
      setGroups(parseMetrics(text));
      setError(null);
    } catch (e: unknown) { setError(String(e)); }
    finally { setLoading(false); }
  }, []);

  useEffect(() => { load(); }, [load]);

  return (
    <div>
      <div className="page-header">
        <div className="page-title">
          <i className="fas fa-chart-line" />
          <h1>Metrics</h1>
        </div>
        <div style={{ display: 'flex', gap: 8 }}>
          <button
            className={`btn btn-sm ${view === 'parsed' ? 'btn-primary' : 'btn-ghost'}`}
            onClick={() => setView('parsed')}
          >Parsed</button>
          <button
            className={`btn btn-sm ${view === 'raw' ? 'btn-primary' : 'btn-ghost'}`}
            onClick={() => setView('raw')}
          >Raw</button>
          <button className="btn btn-ghost btn-sm" onClick={load}>
            <i className="fas fa-sync-alt" /> Refresh
          </button>
        </div>
      </div>

      {error && <div className="error-banner"><i className="fas fa-exclamation-circle" />{error}</div>}

      {loading ? (
        <div style={{ display: 'flex', justifyContent: 'center', padding: '60px' }}>
          <div className="spinner" />
        </div>
      ) : view === 'raw' ? (
        <div className="card">
          <pre className="mono" style={{ fontSize: 12, whiteSpace: 'pre-wrap', color: 'var(--color-text-secondary)', overflowX: 'auto' }}>
            {raw || '(empty)'}
          </pre>
        </div>
      ) : (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
          {groups.length === 0 ? (
            <div className="card" style={{ color: 'var(--color-muted)', textAlign: 'center' }}>
              No metrics yet — they appear once requests flow through the proxy.
            </div>
          ) : (
            groups.map((g, gi) => (
              <div key={gi} className="card">
                <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 10 }}>
                  <span style={{ fontWeight: 600, color: 'var(--color-text)', fontSize: 13 }}>
                    {g.help.split(' ')[0]}
                  </span>
                  <span className="badge badge-purple" style={{ fontSize: 10 }}>{g.type}</span>
                  <span style={{ color: 'var(--color-muted)', fontSize: 12 }}>
                    {g.help.slice(g.help.indexOf(' ') + 1)}
                  </span>
                </div>
                <table>
                  <tbody>
                    {g.lines.map((line, li) => {
                      const m = line.match(/^([^{]+)(\{[^}]*\})?\s+(.+)$/);
                      if (!m) return null;
                      const [, name, labels, value] = m;
                      return (
                        <tr key={li}>
                          <td className="mono" style={{ color: 'var(--color-text)', fontSize: 12 }}>
                            {name}{labels && <span style={{ color: 'var(--color-muted)' }}>{labels}</span>}
                          </td>
                          <td className="mono" style={{ color: 'var(--color-primary)', fontWeight: 600, textAlign: 'right', whiteSpace: 'nowrap' }}>
                            {value}
                          </td>
                        </tr>
                      );
                    })}
                  </tbody>
                </table>
              </div>
            ))
          )}
        </div>
      )}
    </div>
  );
}
