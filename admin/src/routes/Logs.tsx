import FaIcon from "@/components/FaIcon";
import { useEffect, useState } from 'react';
import { openRealtimeStream, type LogEntry, type RealtimeSnapshot } from '@/api/client';
import { formatDateTime } from '@/utils/dateFormat';
import styles from './Logs.module.css';

function levelClass(level?: string): string {
  if (!level) return '';
  const l = level.toLowerCase();
  if (l === 'error') return styles.levelError;
  if (l === 'warn') return styles.levelWarn;
  return styles.levelInfo;
}

function isWebSocketUpgradeLog(e: LogEntry): boolean {
  return (
    e.status === 101 &&
    (e.path === '/api/realtime' || (e.message ?? '').toLowerCase().includes('/api/realtime'))
  );
}

/** Display protocol as HTTP/1.1, HTTP/2, HTTP/3; append encoding if present. */
function protoEncDisplay(e: LogEntry): string {
  if (isWebSocketUpgradeLog(e)) {
    return 'WS';
  }
  const p = e.protocol?.trim() || '';
  const enc = e.encoding?.trim().toLowerCase() || '';
  const protocolLabel =
    p === '1.1' ? 'HTTP/1.1' : p === '2' ? 'HTTP/2' : p === '3' ? 'HTTP/3' : p || '—';
  if (enc && protocolLabel !== '—') return `${protocolLabel} · ${enc}`;
  return protocolLabel;
}

/** CSS class for protocol color (HTTP/1.1, HTTP/2, HTTP/3). */
function protoColorClass(e: LogEntry): string {
  if (isWebSocketUpgradeLog(e)) return styles.protoWs;
  const p = e.protocol?.trim() || '';
  if (p === '1.1') return styles.proto11;
  if (p === '2') return styles.proto2;
  if (p === '3') return styles.proto3;
  return '';
}

type LogFilterType = 'all' | 'system' | 'proxy';

type LogsProps = {
  initialLogType?: LogFilterType | 'crash_error';
};

/** Match a status code against a comma-separated filter string.
 *  Each token may be a number ("404") or a range shorthand ("4xx", "5xx", etc.).
 */
function matchesStatusFilter(status: number | undefined, filter: string): boolean {
  const trimmed = filter.trim();
  if (!trimmed) return true;
  if (status == null) return false;
  const parts = trimmed.split(',').map(p => p.trim().toLowerCase()).filter(Boolean);
  return parts.some(p => {
    if (/^[1-9]xx$/.test(p)) {
      const base = parseInt(p[0], 10) * 100;
      return status >= base && status < base + 100;
    }
    const n = parseInt(p, 10);
    return !isNaN(n) && status === n;
  });
}

export default function Logs({ initialLogType = 'all' }: LogsProps) {
  const [entries, setEntries] = useState<LogEntry[]>([]);
  const [loading, setLoading] = useState(true);
  const [autoRefresh, setAutoRefresh] = useState(true);
  const [logType, setLogType] = useState<LogFilterType | 'crash_error'>(initialLogType);
  const [hostFilter, setHostFilter] = useState('');
  const [statusFilter, setStatusFilter] = useState('');

  useEffect(() => {
    let hasFrame = false;
    const firstFrameTimer = window.setTimeout(() => {
      if (!hasFrame) setLoading(false);
    }, 5000);

    function acceptType(entry: LogEntry): boolean {
      if (logType === 'all') return true;
      if (logType === 'proxy') return entry.type === 'proxy' || entry.type === 'request' || entry.type === 'response';
      if (logType === 'crash_error') {
        const message = (entry.message ?? '').toLowerCase();
        return (
          entry.level === 'error' ||
          entry.type === 'error' ||
          message.includes('crash') ||
          message.includes('exception') ||
          message.includes('fatal')
        );
      }
      return entry.type === 'system' || entry.type === 'error';
    }

    function filterLogs(logs: LogEntry[]): LogEntry[] {
      const hostNeedle = hostFilter.trim().toLowerCase();
      return logs.filter((entry) => {
        if (!acceptType(entry)) return false;
        if (hostNeedle && !(entry.host ?? '').toLowerCase().includes(hostNeedle)) return false;
        if (!matchesStatusFilter(entry.status, statusFilter)) return false;
        return true;
      });
    }

    function onRealtime(snapshot: RealtimeSnapshot) {
      hasFrame = true;
      if (!autoRefresh) return;
      const logs = Array.isArray(snapshot.logs) ? snapshot.logs : [];
      setEntries(filterLogs(logs));
      setLoading(false);
    }

    const stop = openRealtimeStream(onRealtime, () => {
      if (!hasFrame) setLoading(false);
    });

    return () => {
      window.clearTimeout(firstFrameTimer);
      stop();
    };
  }, [autoRefresh, logType, hostFilter, statusFilter]);

  return (
    <section className={styles.section}>
      <div className={styles.header}>
        <div className={styles.filters}>
          <div className={styles.dropdownWrap}>
            <label className={styles.dropdownLabel}>Type</label>
            <div className={styles.dropdownInner}>
              <select
                className={styles.dropdown}
                value={logType}
                onChange={(e) => setLogType(e.target.value as LogFilterType | 'crash_error')}
                title="Filter by log type"
                aria-label="Log type filter"
              >
                <option value="all">All logs</option>
                <option value="system">System logs</option>
                <option value="proxy">Domain logs</option>
                <option value="crash_error">Crash/Error logs</option>
              </select>
              <span className={styles.dropdownChevron} aria-hidden>
                <FaIcon className="fas fa-chevron-down" />
              </span>
            </div>
          </div>
          {(logType === 'proxy' || logType === 'all' || logType === 'crash_error') && (
            <div className={styles.dropdownWrap}>
              <label className={styles.dropdownLabel}>Host</label>
              <input
                type="text"
                className={styles.hostInput}
                placeholder="Filter by host…"
                value={hostFilter}
                onChange={(e) => setHostFilter(e.target.value)}
                title="Filter by domain/host name"
                aria-label="Host filter"
              />
            </div>
          )}
          {(logType === 'proxy' || logType === 'all' || logType === 'crash_error') && (
            <div className={styles.dropdownWrap}>
              <label className={styles.dropdownLabel}>Status</label>
              <input
                type="text"
                className={styles.hostInput}
                placeholder="e.g. 404, 5xx, 200"
                value={statusFilter}
                onChange={(e) => setStatusFilter(e.target.value)}
                title="Filter by HTTP status: comma-separated codes or patterns like 4xx, 5xx"
                aria-label="Status filter"
              />
            </div>
          )}
          <label className={styles.checkbox}>
            <input
              type="checkbox"
              checked={autoRefresh}
              onChange={(e) => setAutoRefresh(e.target.checked)}
              aria-label="Live updates"
            />
            <span>Live updates</span>
          </label>
        </div>
      </div>
      <div className={styles.wrap}>
        <table className={styles.table}>
          <thead>
            <tr>
              <th>Time</th>
              <th>Level</th>
              <th>Method</th>
              <th className={styles.colProtoEnc}>Protocol</th>
              <th>Host</th>
              <th>Path</th>
              <th>Upstream</th>
              <th>Status</th>
              <th>Duration</th>
              <th>Message</th>
            </tr>
          </thead>
          <tbody>
            {loading && entries.length === 0 ? (
              <tr>
                <td colSpan={10} className={styles.loading}>
                  Loading…
                </td>
              </tr>
            ) : entries.length === 0 ? (
              <tr>
                <td colSpan={10} className={styles.loading}>
                  No log entries yet.
                </td>
              </tr>
            ) : (
              entries.map((e, i) => (
                <tr key={i}>
                  <td className={styles.ts}>
                    {e.timestamp ? formatDateTime(e.timestamp) : '—'}
                  </td>
                  <td className={levelClass(e.level)}>{e.level ?? '—'}</td>
                  <td className={styles.method}>{e.method ?? '—'}</td>
                  <td className={`${styles.protoEnc} ${protoColorClass(e)}`}>{protoEncDisplay(e)}</td>
                  <td>{e.host ?? '—'}</td>
                  <td>{e.path ?? '—'}</td>
                  <td>{e.upstream ?? '—'}</td>
                  <td>{e.status ?? '—'}</td>
                  <td>{e.duration_ms != null ? `${e.duration_ms} ms` : '—'}</td>
                  <td>{e.message || '—'}</td>
                </tr>
              ))
            )}
          </tbody>
        </table>
      </div>
    </section>
  );
}
