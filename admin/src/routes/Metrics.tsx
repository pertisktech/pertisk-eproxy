import { useEffect, useState, useMemo, type CSSProperties } from 'react';
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
import {
  api,
  openRealtimeStream,
  type RealtimeSnapshot,
  type Metrics,
  type ManagementInfo,
} from '@/api/client';
import { formatTimeOnly } from '@/utils/dateFormat';
import styles from './Metrics.module.css';

const MAX_POINTS = 60; // 5 min at 5s interval

/** Recharts defaults to a white tooltip box; without explicit colors, labels can match the background. */
const METRICS_TOOLTIP_CONTENT: CSSProperties = {
  backgroundColor: 'var(--color-card)',
  border: '1px solid var(--color-border-light)',
  borderRadius: 'var(--radius-sm)',
  boxShadow: 'var(--shadow-sm)',
  color: 'var(--color-text)',
};
const METRICS_TOOLTIP_LABEL: CSSProperties = {
  color: 'var(--color-text)',
  fontWeight: 600,
};
const METRICS_TOOLTIP_ITEM: CSSProperties = {
  color: 'var(--color-text)',
};

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
  tMs: number;
  timeLabel: string;
  http_rps: number;
  https_rps: number;
  h3_rps: number;
  grpc_rps: number;
}

interface ThroughputTrendPoint {
  tMs: number;
  timeLabel: string;
  sent_kibps: number;
  recv_kibps: number;
}

function formatTime(ms: number): string {
  return formatTimeOnly(new Date(ms).toISOString());
}

function formatMemoryMb(value: number): string {
  return `${value.toFixed(2)} MB`;
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

/** Y-axis numeric ticks — always two fractional digits (with locale grouping). */
function formatChartAxisNumber(v: number): string {
  if (!Number.isFinite(v)) return '';
  return new Intl.NumberFormat(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 }).format(v);
}

/** X-axis time ticks — two-digit hour, minute, second (local). */
function formatChartAxisTimeMs(ms: number): string {
  if (!Number.isFinite(ms)) return '';
  const d = new Date(ms);
  const hh = String(d.getHours()).padStart(2, '0');
  const mm = String(d.getMinutes()).padStart(2, '0');
  const ss = String(d.getSeconds()).padStart(2, '0');
  return `${hh}:${mm}:${ss}`;
}

/** Tooltip / legend time label when X is epoch ms or a string fallback. */
function formatChartTooltipXLabel(label: unknown): string {
  if (typeof label === 'number' && Number.isFinite(label)) return formatChartAxisTimeMs(label);
  if (typeof label === 'string' && label.trim() !== '' && /^\d+$/.test(label.trim())) {
    return formatChartAxisTimeMs(Number(label));
  }
  if (label == null) return '';
  return String(label);
}
function formatTooltipMetricValue(value: number): string {
  if (!Number.isFinite(value)) return '—';
  if (Number.isInteger(value) || Math.abs(value - Math.round(value)) < 1e-6) {
    return Math.round(value).toLocaleString();
  }
  return value.toFixed(2);
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

function memoryMbFromMgmt(mgmt: ManagementInfo): number | null {
  const raw =
    mgmt.process_memory_bytes ??
    (typeof mgmt.process_info?.memory_total_bytes === 'number' ? mgmt.process_info.memory_total_bytes : null);
  if (raw == null || !Number.isFinite(Number(raw))) return null;
  return Math.round((num(raw) / (1024 * 1024)) * 100) / 100;
}

function buildMetricPoint(m: Metrics, mgmt: ManagementInfo, t: number): MetricPoint {
  const rec = m as unknown as Record<string, unknown>;
  const hasRequestTotals =
    typeof rec.http_requests_total === 'number' &&
    typeof rec.https_requests_total === 'number' &&
    typeof rec.grpc_requests_total === 'number';
  const h2 = num(m.h2_requests_total);
  const h3 = num(m.h3_requests_total);
  return {
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
    memory_used_mb: memoryMbFromMgmt(mgmt),
  };
}

export default function Metrics() {
  const [history, setHistory] = useState<MetricPoint[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [missingRequestTotals, setMissingRequestTotals] = useState(false);

  useEffect(() => {
    let cancelled = false;
    let stopWs: (() => void) | undefined;

    function applySnapshot(snapshot: RealtimeSnapshot) {
      const m = snapshot.stats;
      const mgmt = snapshot.management;
      const rec = m as unknown as Record<string, unknown>;
      const hasRequestTotals =
        typeof rec.http_requests_total === 'number' &&
        typeof rec.https_requests_total === 'number' &&
        typeof rec.grpc_requests_total === 'number';
      setMissingRequestTotals(!hasRequestTotals);
      const t = Date.now();
      setHistory((prev) => [...prev, buildMetricPoint(m, mgmt, t)].slice(-MAX_POINTS));
      setError(null);
    }

    (async () => {
      try {
        const [st1, mg1] = await Promise.all([api.metrics(), api.management()]);
        if (cancelled) return;
        const t1 = Date.now();
        const p1 = buildMetricPoint(st1, mg1, t1);
        await new Promise<void>((r) => {
          setTimeout(r, 450);
        });
        const [st2, mg2] = await Promise.all([api.metrics(), api.management()]);
        if (cancelled) return;
        const t2 = Date.now();
        const p2 = buildMetricPoint(st2, mg2, t2);
        const rec2 = st2 as unknown as Record<string, unknown>;
        setMissingRequestTotals(
          !(
            typeof rec2.http_requests_total === 'number' &&
            typeof rec2.https_requests_total === 'number' &&
            typeof rec2.grpc_requests_total === 'number'
          )
        );
        setHistory([p1, p2]);
        setError(null);
      } catch (e: unknown) {
        if (!cancelled) {
          setError(String(e));
        }
      }

      if (cancelled) return;
      stopWs = openRealtimeStream(applySnapshot);
    })();

    return () => {
      cancelled = true;
      stopWs?.();
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
        tMs: curr.t,
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
        tMs: curr.t,
        timeLabel: curr.timeLabel,
        sent_kibps: sent,
        recv_kibps: recv,
      });
    }
    return out;
  }, [history]);

  const requestRateChartMax = useMemo(() => {
    if (requestsTrend.length === 0) return 1;
    let mx = 0;
    for (const p of requestsTrend) {
      mx = Math.max(mx, p.http_rps, p.https_rps, p.h3_rps, p.grpc_rps);
    }
    return mx <= 0 ? 1 : mx * 1.15;
  }, [requestsTrend]);

  const throughputChartMax = useMemo(() => {
    if (throughputTrend.length === 0) return 0.5;
    let mx = 0;
    for (const p of throughputTrend) {
      mx = Math.max(mx, p.sent_kibps, p.recv_kibps);
    }
    return mx <= 0 ? 0.5 : mx * 1.2;
  }, [throughputTrend]);

  const runtimeLeftMax = useMemo(() => {
    if (history.length === 0) return 8;
    let mx = 2;
    for (const p of history) {
      mx = Math.max(mx, p.active_connections, p.cpu_percent ?? 0);
    }
    return Math.max(4, Math.ceil(mx * 1.15));
  }, [history]);

  const runtimeRightMax = useMemo(() => {
    if (history.length === 0) return 100;
    let mx = 8;
    for (const p of history) {
      mx = Math.max(mx, p.log_entries, p.memory_used_mb ?? 0);
    }
    return Math.max(16, Math.ceil(mx * 1.1));
  }, [history]);

  const ratesAllNearZero = useMemo(
    () =>
      requestsTrend.length > 0 &&
      requestsTrend.every(
        (p) =>
          Math.abs(p.http_rps) < 1e-9 &&
          Math.abs(p.https_rps) < 1e-9 &&
          Math.abs(p.h3_rps) < 1e-9 &&
          Math.abs(p.grpc_rps) < 1e-9
      ),
    [requestsTrend]
  );

  const tpAllNearZero = useMemo(
    () =>
      throughputTrend.length > 0 &&
      throughputTrend.every((p) => Math.abs(p.sent_kibps) < 1e-9 && Math.abs(p.recv_kibps) < 1e-9),
    [throughputTrend]
  );

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
      {missingRequestTotals && (
        <div className={styles.errorCard}>
          <span className={styles.errorIcon} aria-hidden>!</span>
          <span>
            Stats payload is missing one or more request total fields. Protocol rate lines may be incomplete until the
            backend exposes full counters.
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
                <span className={styles.summaryValue}>{currentSnapshot.latest.cpu_percent.toFixed(2)}%</span>
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
              No proxied traffic observed yet. Request totals count traffic through the reverse proxy (not the admin UI
              or management API).
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
                  type="number"
                  dataKey="tMs"
                  domain={['dataMin', 'dataMax']}
                  tick={{ fontSize: 11 }}
                  className={styles.axis}
                  interval="preserveStartEnd"
                  tickFormatter={(v) => formatChartAxisTimeMs(Number(v))}
                />
                <YAxis
                  tick={{ fontSize: 11 }}
                  className={styles.axis}
                  domain={[0, requestRateChartMax]}
                  allowDataOverflow
                  tickFormatter={(v) => formatChartAxisNumber(Number(v))}
                />
                <Tooltip
                  contentStyle={METRICS_TOOLTIP_CONTENT}
                  labelStyle={METRICS_TOOLTIP_LABEL}
                  itemStyle={METRICS_TOOLTIP_ITEM}
                  formatter={(value: unknown, name: string) => [
                    typeof value === 'number' && Number.isFinite(value) ? formatRate(value) : '—',
                    name,
                  ]}
                  labelFormatter={(label) => formatChartTooltipXLabel(label)}
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
        {ratesAllNearZero && requestsTrend.length > 0 && (
          <p className={styles.chartHint}>
            Lines are at zero: no proxied request rate in this window, or counters are unchanged between samples. Send
            traffic through the proxy to see HTTP/1.x move; HTTPS/H3/gRPC stay at zero unless those paths are used.
          </p>
        )}
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
                  type="number"
                  dataKey="tMs"
                  domain={['dataMin', 'dataMax']}
                  tick={{ fontSize: 11 }}
                  className={styles.axis}
                  interval="preserveStartEnd"
                  tickFormatter={(v) => formatChartAxisTimeMs(Number(v))}
                />
                <YAxis
                  tick={{ fontSize: 11 }}
                  className={styles.axis}
                  tickFormatter={(v) => formatChartAxisNumber(Number(v))}
                  domain={[0, throughputChartMax]}
                  allowDataOverflow
                />
                <Tooltip
                  contentStyle={METRICS_TOOLTIP_CONTENT}
                  labelStyle={METRICS_TOOLTIP_LABEL}
                  itemStyle={METRICS_TOOLTIP_ITEM}
                  formatter={(value: unknown, name: string) => [
                    typeof value === 'number' && Number.isFinite(value) ? `${value.toFixed(2)} KiB/s` : '—',
                    name,
                  ]}
                  labelFormatter={(label) => formatChartTooltipXLabel(label)}
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
        {tpAllNearZero && throughputTrend.length > 0 && (
          <p className={styles.chartHint}>
            Throughput is zero in this window: no proxied traffic with bodies, or only tiny responses. Counts include
            request/response body bytes through the TCP proxy and HTTP/3 gateway (not headers, WebSocket streams, or
            management API JSON).
          </p>
        )}
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
                <XAxis
                  type="number"
                  dataKey="t"
                  domain={['dataMin', 'dataMax']}
                  tick={{ fontSize: 11 }}
                  className={styles.axis}
                  interval="preserveStartEnd"
                  tickFormatter={(v) => formatChartAxisTimeMs(Number(v))}
                />
                <YAxis
                  yAxisId="left"
                  tick={{ fontSize: 11 }}
                  className={styles.axis}
                  domain={[0, runtimeLeftMax]}
                  allowDataOverflow
                  tickFormatter={(v) => formatChartAxisNumber(Number(v))}
                />
                <YAxis
                  yAxisId="right"
                  orientation="right"
                  tick={{ fontSize: 11 }}
                  className={styles.axis}
                  domain={[0, runtimeRightMax]}
                  allowDataOverflow
                  tickFormatter={(v) => formatChartAxisNumber(Number(v))}
                />
                <Tooltip
                  contentStyle={METRICS_TOOLTIP_CONTENT}
                  labelStyle={METRICS_TOOLTIP_LABEL}
                  itemStyle={METRICS_TOOLTIP_ITEM}
                  formatter={(value: unknown, name: string) => {
                    if (name === 'CPU %')
                      return [typeof value === 'number' && Number.isFinite(value) ? `${value.toFixed(2)}%` : '—', name];
                    if (name === 'Memory (MB)')
                      return [typeof value === 'number' && Number.isFinite(value) ? formatMemoryMb(value) : '—', name];
                    return [
                      typeof value === 'number' && Number.isFinite(value) ? formatTooltipMetricValue(value) : '—',
                      name,
                    ];
                  }}
                  labelFormatter={(label) => formatChartTooltipXLabel(label)}
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
