import { useEffect, useState, useMemo } from 'react';
import {
  Area,
  AreaChart,
  Line,
  LineChart,
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip,
  ResponsiveContainer,
  Legend,
} from 'recharts';
import { api, type Metrics as ApiMetrics, type ManagementInfo } from '@/api/client';
import { formatTimeOnly } from '@/utils/dateFormat';
import styles from './Metrics.module.css';

const POLL_INTERVAL_MS = 5000;
const MAX_POINTS = 60; // 5 min at 5s interval

export interface MetricPoint {
  t: number;
  timeLabel: string;
  mode: string;
  uptime_secs: number;
  log_entries: number;
  active_connections: number;
  http_requests_total: number;
  https_requests_total: number;
  grpc_requests_total: number;
  h2_requests_total: number;
  h3_requests_total: number;
  h3_vs_h2_ratio: number;
  bytes_sent_total: number;
  bytes_received_total: number;
  connections_per_site: Record<string, number>;
  site_h2_requests_total: Record<string, number>;
  site_h3_requests_total: Record<string, number>;
  site_h3_vs_h2_ratio: Record<string, number>;
  cpu_percent: number | null;
  memory_used_mb: number | null;
}

interface HostProtocolRow {
  host: string;
  activeConnections: number;
  h2: number;
  h3: number;
  ratio: number;
}

interface RequestsTrendPoint {
  timeLabel: string;
  http_rps: number;
  https_rps: number;
  h3_rps: number;
  grpc_rps: number;
}

interface ThroughputTrendPoint {
  timeLabel: string;
  sent_kibps: number;
  recv_kibps: number;
}

function formatTime(ms: number): string {
  return formatTimeOnly(new Date(ms).toISOString());
}

function formatMemoryMb(value: number): string {
  return `${value.toFixed(1)} MB`;
}

function formatThroughputKiB(value: number): string {
  return `${value.toFixed(2)} KiB/s`;
}

function formatBytes(value: number): string {
  if (value < 1024) return `${value} B`;
  const kib = value / 1024;
  if (kib < 1024) return `${kib.toFixed(1)} KiB`;
  const mib = kib / 1024;
  if (mib < 1024) return `${mib.toFixed(1)} MiB`;
  const gib = mib / 1024;
  return `${gib.toFixed(2)} GiB`;
}

function deltaRate(curr: number, prev: number, seconds: number): number {
  if (seconds <= 0) return 0;
  if (curr < prev) return 0;
  return (curr - prev) / seconds;
}

function formatRate(value: number): string {
  const n = Number(value);
  if (!Number.isFinite(n)) return '—';
  return `${n.toFixed(2)}/s`;
}

/** Coerce API / JSON values to a finite number (admin /stats may omit fields). */
function num(v: unknown, fallback = 0): number {
  if (typeof v === 'number' && Number.isFinite(v)) return v;
  if (typeof v === 'string' && v.trim() !== '') {
    const n = Number(v);
    if (Number.isFinite(n)) return n;
  }
  return fallback;
}

function localeInt(n: number | null | undefined): string {
  return num(n, 0).toLocaleString();
}

function selectBaselinePoint(history: MetricPoint[], windowMs: number): MetricPoint | null {
  if (history.length < 2) return null;
  const latest = history[history.length - 1];
  for (let i = history.length - 2; i >= 0; i -= 1) {
    if (latest.t - history[i].t >= windowMs) return history[i];
  }
  return history[history.length - 2] ?? null;
}

export default function Metrics() {
  const [history, setHistory] = useState<MetricPoint[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [missingRequestTotals, setMissingRequestTotals] = useState(false);

  useEffect(() => {
    let cancelled = false;

    function tick() {
      Promise.all([api.metrics(), api.management()])
        .then(([m, mgmt]: [ApiMetrics, ManagementInfo]) => {
          if (cancelled) return;
          const hasRequestTotals =
            typeof (m as unknown as Record<string, unknown>).http_requests_total === 'number' &&
            typeof (m as unknown as Record<string, unknown>).https_requests_total === 'number' &&
            typeof (m as unknown as Record<string, unknown>).grpc_requests_total === 'number';
          setMissingRequestTotals(!hasRequestTotals);
          const t = Date.now();
          const h2 = num(m.h2_requests_total);
          const h3 = num(m.h3_requests_total);
          const point: MetricPoint = {
            t,
            timeLabel: formatTime(t),
            mode: typeof mgmt.mode === 'string' && mgmt.mode ? mgmt.mode : 'proxy',
            uptime_secs: num(m.uptime_secs),
            log_entries: num(m.log_entries),
            active_connections: num(m.active_connections),
            http_requests_total: hasRequestTotals ? num(m.http_requests_total) : h2 + h3,
            https_requests_total: hasRequestTotals ? num(m.https_requests_total) : 0,
            grpc_requests_total: hasRequestTotals ? num(m.grpc_requests_total) : 0,
            h2_requests_total: h2,
            h3_requests_total: h3,
            h3_vs_h2_ratio: num(m.h3_vs_h2_ratio),
            bytes_sent_total: num(m.bytes_sent_total),
            bytes_received_total: num(m.bytes_received_total),
            connections_per_site: m.connections_per_site ?? {},
            site_h2_requests_total: m.site_h2_requests_total ?? {},
            site_h3_requests_total: m.site_h3_requests_total ?? {},
            site_h3_vs_h2_ratio: m.site_h3_vs_h2_ratio ?? {},
            cpu_percent: mgmt.process_cpu_usage_percent ?? null,
            memory_used_mb:
              mgmt.process_memory_bytes != null
                ? Math.round(num(mgmt.process_memory_bytes) / (1024 * 1024) * 10) / 10
                : null,
          };
          setHistory((prev) => {
            const next = [...prev, point].slice(-MAX_POINTS);
            return next;
          });
          setError(null);
        })
        .catch((e) => {
          if (!cancelled) setError(e instanceof Error ? e.message : 'Failed to load metrics');
        })
        .finally(() => {
          if (!cancelled) setLoading(false);
        });
    }

    tick();
    const id = setInterval(tick, POLL_INTERVAL_MS);
    return () => {
      cancelled = true;
      clearInterval(id);
    };
  }, []);

  const hasCpu = useMemo(() => history.some((p) => p.cpu_percent != null), [history]);
  const hasMemory = useMemo(() => history.some((p) => p.memory_used_mb != null), [history]);

  const requestsTrend = useMemo<RequestsTrendPoint[]>(() => {
    if (history.length < 2) return [];
    const out: RequestsTrendPoint[] = [];
    for (let i = 1; i < history.length; i += 1) {
      const prev = history[i - 1];
      const curr = history[i];
      const seconds = (curr.t - prev.t) / 1000;
      out.push({
        timeLabel: curr.timeLabel,
        http_rps: deltaRate(curr.http_requests_total, prev.http_requests_total, seconds),
        https_rps: deltaRate(curr.https_requests_total, prev.https_requests_total, seconds),
        h3_rps: deltaRate(curr.h3_requests_total, prev.h3_requests_total, seconds),
        grpc_rps: deltaRate(curr.grpc_requests_total, prev.grpc_requests_total, seconds),
      });
    }
    return out;
  }, [history]);

  const throughputTrend = useMemo<ThroughputTrendPoint[]>(() => {
    if (history.length < 2) return [];
    const out: ThroughputTrendPoint[] = [];
    for (let i = 1; i < history.length; i += 1) {
      const prev = history[i - 1];
      const curr = history[i];
      const seconds = (curr.t - prev.t) / 1000;
      const sent = deltaRate(curr.bytes_sent_total, prev.bytes_sent_total, seconds) / 1024;
      const recv = deltaRate(curr.bytes_received_total, prev.bytes_received_total, seconds) / 1024;
      out.push({
        timeLabel: curr.timeLabel,
        sent_kibps: sent,
        recv_kibps: recv,
      });
    }
    return out;
  }, [history]);

  const hostProtocolRows = useMemo<HostProtocolRow[]>(() => {
    if (history.length === 0) return [];
    const latest = history[history.length - 1];
    const hosts = new Set<string>([
      ...Object.keys(latest.connections_per_site ?? {}),
      ...Object.keys(latest.site_h2_requests_total ?? {}),
      ...Object.keys(latest.site_h3_requests_total ?? {}),
      ...Object.keys(latest.site_h3_vs_h2_ratio ?? {}),
    ]);
    return Array.from(hosts)
      .map((host) => ({
        host,
        activeConnections: num(latest.connections_per_site?.[host]),
        h2: num(latest.site_h2_requests_total?.[host]),
        h3: num(latest.site_h3_requests_total?.[host]),
        ratio: num(latest.site_h3_vs_h2_ratio?.[host]),
      }))
      .sort((a, b) => {
        const aScore = a.activeConnections + a.h2 + a.h3;
        const bScore = b.activeConnections + b.h2 + b.h3;
        if (bScore !== aScore) return bScore - aScore;
        return a.host.localeCompare(b.host);
      });
  }, [history]);

  const currentSnapshot = useMemo(() => {
    if (history.length === 0) return null;
    const latest = history[history.length - 1];
    const baseline = selectBaselinePoint(history, 30_000);

    if (!baseline) {
      return {
        latest,
        req_total_rps: null as number | null,
        h2_rps: null as number | null,
        h3_rps: null as number | null,
        sent_kibps: null as number | null,
        recv_kibps: null as number | null,
        sampleWindowSec: null as number | null,
      };
    }

    const seconds = (latest.t - baseline.t) / 1000;
    const req_total_rps = deltaRate(
      latest.http_requests_total + latest.https_requests_total + latest.grpc_requests_total,
      baseline.http_requests_total + baseline.https_requests_total + baseline.grpc_requests_total,
      seconds
    );
    const h2_rps = deltaRate(latest.h2_requests_total, baseline.h2_requests_total, seconds);
    const h3_rps = deltaRate(latest.h3_requests_total, baseline.h3_requests_total, seconds);
    const sent_kibps = deltaRate(latest.bytes_sent_total, baseline.bytes_sent_total, seconds) / 1024;
    const recv_kibps = deltaRate(latest.bytes_received_total, baseline.bytes_received_total, seconds) / 1024;

    return {
      latest,
      req_total_rps,
      h2_rps,
      h3_rps,
      sent_kibps,
      recv_kibps,
      sampleWindowSec: seconds,
    };
  }, [history]);

  const noProxyTrafficObserved = useMemo(() => {
    if (!currentSnapshot) return false;
    const latest = currentSnapshot.latest;
    const total =
      num(latest.http_requests_total) + num(latest.https_requests_total) + num(latest.grpc_requests_total);
    return num(latest.uptime_secs) > 60 && total === 0;
  }, [currentSnapshot]);

  if (error && history.length === 0) {
    return (
      <div className={styles.page}>
        <div className={styles.errorCard}>
          <span className={styles.errorIcon} aria-hidden>!</span>
          <span>{error}</span>
        </div>
      </div>
    );
  }

  return (
    <div className={styles.page}>
      {!loading && history.length > 0 && (
        <div className="page-actions" style={{ marginBottom: 16 }}>
          <span className={styles.liveBadge} title="Auto-refresh">
            Live
          </span>
        </div>
      )}

      {missingRequestTotals && (
        <div className={styles.errorCard}>
          <span className={styles.errorIcon} aria-hidden>!</span>
          <span>
            Ingress backend is missing HTTP/HTTPS request counters in /api/metrics. Showing fallback rates from H2/H3 protocol counters; redeploy ingress with the latest binary for full request totals.
          </span>
        </div>
      )}

      {currentSnapshot && (
        <section className={styles.summarySection}>
          <h2 className={styles.sectionTitle}>Current snapshot</h2>
          <p className={styles.sectionSubtitle}>
            {currentSnapshot.sampleWindowSec == null
              ? 'Collecting traffic sample window…'
              : `Rates are averaged over the last ${Math.max(1, Math.round(currentSnapshot.sampleWindowSec))}s`}
          </p>
          <div className={styles.summaryGrid}>
            <div className={styles.summaryCard}>
              <span className={styles.summaryLabel}>Uptime</span>
              <span className={styles.summaryValue}>{localeInt(currentSnapshot.latest.uptime_secs)} s</span>
            </div>
            <div className={styles.summaryCard}>
              <span className={styles.summaryLabel}>Active connections</span>
              <span className={styles.summaryValue}>{localeInt(currentSnapshot.latest.active_connections)}</span>
            </div>
            <div className={styles.summaryCard}>
              <span className={styles.summaryLabel}>HTTP total</span>
              <span className={styles.summaryValue}>{localeInt(currentSnapshot.latest.http_requests_total)}</span>
            </div>
            <div className={styles.summaryCard}>
              <span className={styles.summaryLabel}>HTTPS total</span>
              <span className={styles.summaryValue}>{localeInt(currentSnapshot.latest.https_requests_total)}</span>
            </div>
            <div className={styles.summaryCard}>
              <span className={styles.summaryLabel}>gRPC total</span>
              <span className={styles.summaryValue}>{localeInt(currentSnapshot.latest.grpc_requests_total)}</span>
            </div>
            <div className={styles.summaryCard}>
              <span className={styles.summaryLabel}>Request rate</span>
              <span className={styles.summaryValue}>
                {currentSnapshot.req_total_rps == null ? 'Collecting…' : formatRate(currentSnapshot.req_total_rps)}
              </span>
            </div>
            <div className={styles.summaryCard}>
              <span className={styles.summaryLabel}>H2 total</span>
              <span className={styles.summaryValue}>{localeInt(currentSnapshot.latest.h2_requests_total)}</span>
            </div>
            <div className={styles.summaryCard}>
              <span className={styles.summaryLabel}>H3 total</span>
              <span className={styles.summaryValue}>{localeInt(currentSnapshot.latest.h3_requests_total)}</span>
            </div>
            <div className={styles.summaryCard}>
              <span className={styles.summaryLabel}>H2 rate</span>
              <span className={styles.summaryValue}>
                {currentSnapshot.h2_rps == null ? 'Collecting…' : formatRate(currentSnapshot.h2_rps)}
              </span>
            </div>
            <div className={styles.summaryCard}>
              <span className={styles.summaryLabel}>H3 rate</span>
              <span className={styles.summaryValue}>
                {currentSnapshot.h3_rps == null ? 'Collecting…' : formatRate(currentSnapshot.h3_rps)}
              </span>
            </div>
            <div className={styles.summaryCard}>
              <span className={styles.summaryLabel}>H3/H2 ratio</span>
              <span className={styles.summaryValue}>
                {currentSnapshot.h2_rps == null
                  ? 'Collecting…'
                  : currentSnapshot.h2_rps <= 0
                    ? '—'
                    : ((currentSnapshot.h3_rps ?? 0) / currentSnapshot.h2_rps).toFixed(3)}
              </span>
            </div>
            <div className={styles.summaryCard}>
              <span className={styles.summaryLabel}>Sent total</span>
              <span className={styles.summaryValue}>{formatBytes(currentSnapshot.latest.bytes_sent_total)}</span>
            </div>
            <div className={styles.summaryCard}>
              <span className={styles.summaryLabel}>Received total</span>
              <span className={styles.summaryValue}>{formatBytes(currentSnapshot.latest.bytes_received_total)}</span>
            </div>
            <div className={styles.summaryCard}>
              <span className={styles.summaryLabel}>Sent throughput</span>
              <span className={styles.summaryValue}>
                {currentSnapshot.sent_kibps == null ? 'Collecting…' : formatThroughputKiB(currentSnapshot.sent_kibps)}
              </span>
            </div>
            <div className={styles.summaryCard}>
              <span className={styles.summaryLabel}>Received throughput</span>
              <span className={styles.summaryValue}>
                {currentSnapshot.recv_kibps == null ? 'Collecting…' : formatThroughputKiB(currentSnapshot.recv_kibps)}
              </span>
            </div>
            {currentSnapshot.latest.cpu_percent != null && (
              <div className={styles.summaryCard}>
                <span className={styles.summaryLabel}>CPU</span>
                <span className={styles.summaryValue}>{currentSnapshot.latest.cpu_percent.toFixed(1)}%</span>
              </div>
            )}
            {currentSnapshot.latest.memory_used_mb != null && (
              <div className={styles.summaryCard}>
                <span className={styles.summaryLabel}>Memory</span>
                <span className={styles.summaryValue}>{formatMemoryMb(currentSnapshot.latest.memory_used_mb)}</span>
              </div>
            )}
          </div>
          {noProxyTrafficObserved && (
            <p className={styles.sectionSubtitle}>
              No proxied traffic observed yet. These counters track requests that pass through PTProxy ingress (not management UI/API calls).
            </p>
          )}
        </section>
      )}

      <section className={styles.chartSection}>
        <h2 className={styles.sectionTitle}>Protocol request rate</h2>
        <p className={styles.sectionSubtitle}>HTTP/1.x, HTTPS, HTTP/3, and gRPC requests per second</p>
        <div className={styles.chartWrap}>
          {requestsTrend.length === 0 ? (
            <div className={styles.chartSkeleton} aria-hidden />
          ) : (
            <ResponsiveContainer width="100%" height={220}>
              <LineChart data={requestsTrend} margin={{ top: 8, right: 16, left: 8, bottom: 8 }} className="chart-theme-text">
                <CartesianGrid strokeDasharray="3 3" className={styles.grid} />
                <XAxis
                  dataKey="timeLabel"
                  tick={{ fontSize: 11 }}
                  className={styles.axis}
                  interval="preserveStartEnd"
                />
                <YAxis tick={{ fontSize: 11 }} className={styles.axis} />
                <Tooltip
                  formatter={(value: unknown, name: string) => [
                    typeof value === 'number' && Number.isFinite(value) ? formatRate(value) : '—',
                    name,
                  ]}
                  labelFormatter={(label) => label}
                />
                <Legend />
                <Line
                  type="monotone"
                  dataKey="http_rps"
                  name="HTTP/1.x"
                  stroke="var(--color-dashboard-metric-quaternary)"
                  strokeWidth={2}
                  dot={false}
                  isAnimationActive={false}
                />
                <Line
                  type="monotone"
                  dataKey="https_rps"
                  name="HTTPS"
                  stroke="var(--color-dashboard-metric-secondary)"
                  strokeWidth={2}
                  dot={false}
                  isAnimationActive={false}
                />
                <Line
                  type="monotone"
                  dataKey="h3_rps"
                  name="HTTP/3"
                  stroke="var(--color-dashboard-metric-tertiary)"
                  strokeWidth={2}
                  dot={false}
                  isAnimationActive={false}
                />
                <Line
                  type="monotone"
                  dataKey="grpc_rps"
                  name="gRPC"
                  stroke="var(--color-dashboard-metric-primary)"
                  strokeWidth={2}
                  dot={false}
                  isAnimationActive={false}
                />
              </LineChart>
            </ResponsiveContainer>
          )}
        </div>
      </section>

      <section className={styles.chartSection}>
        <h2 className={styles.sectionTitle}>Network throughput</h2>
        <p className={styles.sectionSubtitle}>Bytes sent and received per second (KiB/s)</p>
        <div className={styles.chartWrap}>
          {throughputTrend.length === 0 ? (
            <div className={styles.chartSkeleton} aria-hidden />
          ) : (
            <ResponsiveContainer width="100%" height={220}>
              <LineChart data={throughputTrend} margin={{ top: 8, right: 16, left: 8, bottom: 8 }} className="chart-theme-text">
                <CartesianGrid strokeDasharray="3 3" className={styles.grid} />
                <XAxis
                  dataKey="timeLabel"
                  tick={{ fontSize: 11 }}
                  className={styles.axis}
                  interval="preserveStartEnd"
                />
                <YAxis tick={{ fontSize: 11 }} className={styles.axis} tickFormatter={(v) => `${Number(v).toFixed(1)}`} />
                <Tooltip
                  formatter={(value: unknown, name: string) => [
                    typeof value === 'number' && Number.isFinite(value) ? `${value.toFixed(2)} KiB/s` : '—',
                    name,
                  ]}
                  labelFormatter={(label) => label}
                />
                <Legend />
                <Line
                  type="monotone"
                  dataKey="sent_kibps"
                  name="Sent"
                  stroke="var(--color-dashboard-metric-tertiary)"
                  strokeWidth={2}
                  dot={false}
                  isAnimationActive={false}
                />
                <Line
                  type="monotone"
                  dataKey="recv_kibps"
                  name="Received"
                  stroke="var(--color-dashboard-metric-quaternary)"
                  strokeWidth={2}
                  dot={false}
                  isAnimationActive={false}
                />
              </LineChart>
            </ResponsiveContainer>
          )}
        </div>
      </section>

      <section className={styles.chartSection}>
        <h2 className={styles.sectionTitle}>Runtime state</h2>
        <p className={styles.sectionSubtitle}>Connections, log buffer, and process resource usage</p>
        <div className={styles.chartWrap}>
          {history.length === 0 ? (
            <div className={styles.chartSkeleton} aria-hidden />
          ) : (
            <ResponsiveContainer width="100%" height={220}>
              <AreaChart data={history} margin={{ top: 8, right: 16, left: 8, bottom: 8 }} className="chart-theme-text">
                <defs>
                  <linearGradient id="connFill" x1="0" y1="0" x2="0" y2="1">
                    <stop offset="5%" stopColor="var(--color-dashboard-metric-primary)" stopOpacity={0.35} />
                    <stop offset="95%" stopColor="var(--color-dashboard-metric-primary)" stopOpacity={0.02} />
                  </linearGradient>
                  <linearGradient id="logFill" x1="0" y1="0" x2="0" y2="1">
                    <stop offset="5%" stopColor="var(--color-dashboard-metric-secondary)" stopOpacity={0.3} />
                    <stop offset="95%" stopColor="var(--color-dashboard-metric-secondary)" stopOpacity={0.02} />
                  </linearGradient>
                </defs>
                <CartesianGrid strokeDasharray="3 3" className={styles.grid} />
                <XAxis dataKey="timeLabel" tick={{ fontSize: 11 }} className={styles.axis} interval="preserveStartEnd" />
                <YAxis yAxisId="left" tick={{ fontSize: 11 }} className={styles.axis} />
                <YAxis yAxisId="right" orientation="right" tick={{ fontSize: 11 }} className={styles.axis} />
                <Tooltip
                  formatter={(value: unknown, name: string) => {
                    if (name === 'CPU %')
                      return [typeof value === 'number' && Number.isFinite(value) ? `${value.toFixed(1)}%` : '—', name];
                    if (name === 'Memory (MB)')
                      return [typeof value === 'number' && Number.isFinite(value) ? formatMemoryMb(value) : '—', name];
                    return [
                      typeof value === 'number' && Number.isFinite(value) ? value.toLocaleString() : '—',
                      name,
                    ];
                  }}
                  labelFormatter={(label) => label}
                />
                <Legend />
                <Area yAxisId="left" type="monotone" dataKey="active_connections" name="Active connections" stroke="var(--color-dashboard-metric-primary)" fill="url(#connFill)" strokeWidth={2} isAnimationActive={false} />
                <Area yAxisId="right" type="monotone" dataKey="log_entries" name="Log entries" stroke="var(--color-dashboard-metric-secondary)" fill="url(#logFill)" strokeWidth={2} isAnimationActive={false} />
                {hasCpu && (
                  <Line yAxisId="left" type="monotone" dataKey="cpu_percent" name="CPU %" stroke="var(--color-dashboard-warning)" strokeWidth={2} dot={false} isAnimationActive={false} />
                )}
                {hasMemory && (
                  <Line yAxisId="right" type="monotone" dataKey="memory_used_mb" name="Memory (MB)" stroke="var(--color-dashboard-metric-tertiary)" strokeWidth={2} dot={false} isAnimationActive={false} />
                )}
              </AreaChart>
            </ResponsiveContainer>
          )}
        </div>
      </section>

      {hostProtocolRows.length > 0 && (
        <section className={styles.chartSection}>
          <h2 className={styles.sectionTitle}>Ingress host protocol summary</h2>
          <p className={styles.sectionSubtitle}>Active connections and protocol counters by host</p>
          <div className={styles.tableWrap}>
            <table className={styles.table}>
              <thead>
                <tr>
                  <th>Host</th>
                  <th>Active</th>
                  <th>H2</th>
                  <th>H3</th>
                  <th>H3/H2 ratio</th>
                </tr>
              </thead>
              <tbody>
                {hostProtocolRows.map((row) => (
                  <tr key={row.host}>
                    <td>{row.host}</td>
                    <td>{localeInt(row.activeConnections)}</td>
                    <td>{localeInt(row.h2)}</td>
                    <td>{localeInt(row.h3)}</td>
                    <td>{Number.isFinite(row.ratio) ? row.ratio.toFixed(3) : '—'}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </section>
      )}
    </div>
  );
}
