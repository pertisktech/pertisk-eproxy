import { useEffect, useState, useMemo } from 'react';
import {
  Area,
  AreaChart,
  Bar,
  BarChart,
  CartesianGrid,
  Cell,
  Pie,
  PieChart,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from 'recharts';
import {
  api,
  openRealtimeStream,
  type RealtimeSnapshot,
  type Metrics,
  type ManagementInfo,
} from '@/api/client';
import { formatTimeOnly } from '@/utils/dateFormat';
import { formatPertiskVmCpuLine } from '@/utils/beamCpu';
import PrometheusScrapePanel from '@/components/PrometheusScrapePanel';
import {
  ChartEmpty,
  ChartTooltip,
  PageHeader,
  Panel,
  StatCard,
  StatusBadge,
  chartAxisProps,
  chartColors,
  chartGridProps,
  chartMargin,
  formatChartAxisTimeMs,
  formatChartNumber,
  formatChartTooltipXLabel,
  protocolColors,
} from '@/components/console';
import styles from './Metrics.module.css';

const MAX_POINTS = 60; // 5 min at 5s interval
const TOP_SITES = 8;

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
  /** Same source as Dashboard: erlang:memory(total) / process_memory_bytes. */
  memory_bytes: number | null;
  memory_used_mb: number | null;
  logical_processors: number | null;
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
  h2_rps: number;
  h3_rps: number;
  grpc_rps: number;
  /** Cleartext + TLS H1/H2 + H3 + gRPC (eproxy keeps H3 out of https_requests_total). */
  total_rps: number;
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
  const abs = Math.abs(n);
  if (abs >= 100_000) return `${(n / 1000).toFixed(1)}k/s`;
  if (abs >= 10_000) return `${(n / 1000).toFixed(2)}k/s`;
  if (abs >= 100) return `${n.toFixed(0)}/s`;
  return `${n.toFixed(2)}/s`;
}

/** Proxied request totals. H3 is not rolled into https_requests_total on eproxy. */
function totalRequestCount(p: Pick<MetricPoint, 'http_requests_total' | 'https_requests_total' | 'h3_requests_total' | 'grpc_requests_total'>): number {
  return num(p.http_requests_total) + num(p.https_requests_total) + num(p.h3_requests_total) + num(p.grpc_requests_total);
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

function memoryBytesFromMgmt(mgmt: ManagementInfo): number | null {
  const raw =
    mgmt.process_memory_bytes ??
    (typeof mgmt.process_info?.memory_total_bytes === 'number' ? mgmt.process_info.memory_total_bytes : null);
  if (raw == null || !Number.isFinite(Number(raw))) return null;
  return num(raw);
}

function memoryMbFromMgmt(mgmt: ManagementInfo): number | null {
  const b = memoryBytesFromMgmt(mgmt);
  if (b == null) return null;
  return Math.round((b / (1024 * 1024)) * 100) / 100;
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
    memory_bytes: memoryBytesFromMgmt(mgmt),
    memory_used_mb: memoryMbFromMgmt(mgmt),
    logical_processors:
      typeof mgmt.process_info?.logical_processors === 'number' ? mgmt.process_info.logical_processors : null,
  };
}

/** Y-axis upper bound with headroom so flat-zero series still render a readable scale. */
function topDomain(minTop: number, headroom = 1.15): [number, (dataMax: number) => number] {
  return [0, (dataMax: number) => Math.max(minTop, (Number.isFinite(dataMax) ? dataMax : 0) * headroom)];
}

function Legend({ items }: { items: { label: string; color: string }[] }) {
  return (
    <div className={styles.legend}>
      {items.map((item) => (
        <span key={item.label} className={styles.legendItem}>
          <span className={styles.legendDot} style={{ background: item.color }} />
          {item.label}
        </span>
      ))}
    </div>
  );
}

function GradientDef({ id, color, opacity = 0.35 }: { id: string; color: string; opacity?: number }) {
  return (
    <linearGradient id={id} x1="0" y1="0" x2="0" y2="1">
      <stop offset="0%" stopColor={color} stopOpacity={opacity} />
      <stop offset="100%" stopColor={color} stopOpacity={0} />
    </linearGradient>
  );
}

const timeAxis = {
  type: 'number' as const,
  domain: ['dataMin', 'dataMax'] as [string, string],
  interval: 'preserveStartEnd' as const,
  tickFormatter: (v: unknown) => formatChartAxisTimeMs(Number(v)),
  ...chartAxisProps,
};

export default function Metrics() {
  const [history, setHistory] = useState<MetricPoint[]>([]);
  const [management, setManagement] = useState<ManagementInfo | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [missingRequestTotals, setMissingRequestTotals] = useState(false);

  useEffect(() => {
    let cancelled = false;
    let stopWs: (() => void) | undefined;

    function applySnapshot(snapshot: RealtimeSnapshot) {
      const m = snapshot.stats;
      const mgmt = snapshot.management;
      if (!m || typeof m !== 'object') return;
      setManagement(mgmt);
      const rec = m as unknown as Record<string, unknown>;
      const hasRequestTotals =
        typeof rec.http_requests_total === 'number' &&
        typeof rec.https_requests_total === 'number' &&
        typeof rec.grpc_requests_total === 'number';
      setMissingRequestTotals(!hasRequestTotals);
      const t = Date.now();
      setHistory((prev) => {
        const last = prev[prev.length - 1];
        // Keep ~1 sample/sec max so delta rates stay meaningful under bursty frames.
        if (last && t - last.t < 1000) return prev;
        return [...prev, buildMetricPoint(m, mgmt, t)].slice(-MAX_POINTS);
      });
      setError(null);
    }

    (async () => {
      try {
        const [st1, mg1] = await Promise.all([api.metrics(), api.management()]);
        if (cancelled) return;
        setManagement(mg1);
        const t1 = Date.now();
        const p1 = buildMetricPoint(st1, mg1, t1);
        await new Promise<void>((r) => {
          setTimeout(r, 1100);
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
      // Skip sub-second duplicate ticks so rates stay stable under bursty WS delivery.
      if (!Number.isFinite(seconds) || seconds < 0.5) continue;
      const http_rps = deltaRate(curr.http_requests_total, prev.http_requests_total, seconds);
      const https_rps = deltaRate(curr.https_requests_total, prev.https_requests_total, seconds);
      const h2_rps = deltaRate(curr.h2_requests_total, prev.h2_requests_total, seconds);
      const h3_rps = deltaRate(curr.h3_requests_total, prev.h3_requests_total, seconds);
      const grpc_rps = deltaRate(curr.grpc_requests_total, prev.grpc_requests_total, seconds);
      out.push({
        tMs: curr.t,
        timeLabel: curr.timeLabel,
        http_rps,
        https_rps,
        h2_rps,
        h3_rps,
        grpc_rps,
        // Backend: https = tls_h1 + h2 only; H3 and gRPC are separate counters.
        total_rps: http_rps + https_rps + h3_rps + grpc_rps,
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

  const ratesAllNearZero = useMemo(
    () =>
      requestsTrend.length > 0 &&
      requestsTrend.every((p) => Math.abs(p.total_rps) < 1e-9),
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

  const siteBars = useMemo(
    () => hostProtocolRows.filter((r) => r.h2 + r.h3 > 0).slice(0, TOP_SITES),
    [hostProtocolRows],
  );

  const latest = history.length > 0 ? history[history.length - 1] : null;

  const throughputNow = useMemo(() => {
    if (history.length < 2) return null;
    const prev = history[history.length - 2];
    const curr = history[history.length - 1];
    const seconds = (curr.t - prev.t) / 1000;
    if (!Number.isFinite(seconds) || seconds <= 0) return null;
    const sent = deltaRate(curr.bytes_sent_total, prev.bytes_sent_total, seconds);
    const recv = deltaRate(curr.bytes_received_total, prev.bytes_received_total, seconds);
    return sent + recv;
  }, [history]);

  const latestRequestRate = useMemo(() => {
    const last = requestsTrend[requestsTrend.length - 1];
    if (!last) return null;
    return last.total_rps;
  }, [requestsTrend]);

  const totalRequests = latest ? totalRequestCount(latest) : 0;

  const h2Total = latest?.h2_requests_total ?? 0;
  const h3Total = latest?.h3_requests_total ?? 0;
  const h2h3Total = h2Total + h3Total;
  const h3Share = h2h3Total > 0 ? (h3Total / h2h3Total) * 100 : null;
  const h2h3Pie = [
    { name: 'HTTP/2', value: h2Total, color: protocolColors.h2 },
    { name: 'HTTP/3', value: h3Total, color: protocolColors.h3 },
  ].filter((d) => d.value > 0);

  const latestSampleAt = latest ? formatChartAxisTimeMs(latest.t) : '--:--:--';
  const isLive = latest != null && error == null;
  const emptyMsg = 'Waiting for the next sample…';

  if (error && history.length === 0) {
    return (
      <div className={styles.page}>
        <PageHeader title="Metrics" description="Live runtime and traffic telemetry for the proxy node." />
        <div className={styles.errorCard} role="alert">
          <span className={styles.errorIcon} aria-hidden>!</span>
          <span>{error}</span>
        </div>
      </div>
    );
  }

  return (
    <div className={styles.page}>
      <PageHeader
        title="Metrics"
        description="Live runtime and traffic telemetry for the proxy node."
        actions={
          <>
            <StatusBadge tone={isLive ? 'success' : 'muted'} pulse={isLive}>
              {isLive ? `live · ${latestSampleAt}` : 'connecting…'}
            </StatusBadge>
            <StatusBadge tone="muted" dot={false}>
              {latest?.mode ?? 'proxy'} mode
            </StatusBadge>
          </>
        }
      />

      <div className={styles.statGrid} role="group" aria-label="Metrics summary">
        <StatCard
          label="Requests / s"
          value={latestRequestRate != null ? formatRate(latestRequestRate) : '—'}
          hint="all protocols · last sample"
        />
        <StatCard
          label="Total requests"
          value={localeInt(totalRequests)}
          hint={`H2 ${localeInt(h2Total)} · H3 ${localeInt(h3Total)} · gRPC ${localeInt(latest?.grpc_requests_total)}`}
        />
        <StatCard
          label="Active connections"
          value={latest ? localeInt(latest.active_connections) : '0'}
          hint="in-flight upstream sessions"
        />
        <StatCard
          label="Throughput"
          value={throughputNow != null ? `${formatBytes(Math.round(throughputNow))}/s` : '—'}
          hint="send + receive"
        />
        <StatCard
          label="CPU"
          value={latest?.cpu_percent != null ? `${latest.cpu_percent.toFixed(1)}%` : '—'}
          hint={latest?.cpu_percent != null ? formatPertiskVmCpuLine(latest.cpu_percent, latest.logical_processors) : 'Erlang VM'}
        />
        <StatCard
          label="VM memory"
          value={latest?.memory_bytes != null ? formatBytes(latest.memory_bytes) : '—'}
          hint="BEAM allocated"
        />
      </div>

      {missingRequestTotals && (
        <div className={styles.errorCard} role="alert">
          <span className={styles.errorIcon} aria-hidden>!</span>
          <span>
            Stats payload is missing one or more request total fields. Protocol rate lines may be incomplete until the
            backend exposes full counters.
          </span>
        </div>
      )}

      <Panel
        title="Request rate"
        description="Requests per second by protocol (HTTPS = TLS HTTP/1.x + H2; H3 is counted separately)"
        actions={
          <Legend
            items={[
              { label: 'Total', color: chartColors.c1 },
              { label: 'HTTP/1.x', color: protocolColors.http },
              { label: 'HTTPS', color: protocolColors.https },
              { label: 'HTTP/3', color: protocolColors.h3 },
              { label: 'gRPC', color: protocolColors.grpc },
            ]}
          />
        }
      >
        {requestsTrend.length === 0 ? (
          <ChartEmpty message={emptyMsg} />
        ) : (
          <div className={styles.chartBox}>
            <ResponsiveContainer width="100%" height="100%">
              <AreaChart data={requestsTrend} margin={chartMargin}>
                <defs>
                  <GradientDef id="m-fill-total" color={chartColors.c1} opacity={0.2} />
                  <GradientDef id="m-fill-http" color={protocolColors.http} opacity={0.25} />
                  <GradientDef id="m-fill-https" color={protocolColors.https} opacity={0.3} />
                  <GradientDef id="m-fill-h3" color={protocolColors.h3} opacity={0.3} />
                  <GradientDef id="m-fill-grpc" color={protocolColors.grpc} opacity={0.25} />
                </defs>
                <CartesianGrid {...chartGridProps} />
                <XAxis dataKey="tMs" {...timeAxis} />
                <YAxis {...chartAxisProps} width={52} domain={topDomain(1)} tickFormatter={(v) => formatChartNumber(Number(v))} />
                <Tooltip
                  content={
                    <ChartTooltip
                      labelFormatter={formatChartTooltipXLabel}
                      valueFormatter={(v) => formatRate(v)}
                    />
                  }
                />
                <Area type="monotone" dataKey="total_rps" name="Total" stroke={chartColors.c1} strokeWidth={2.5} fill="url(#m-fill-total)" isAnimationActive={false} />
                <Area type="monotone" dataKey="http_rps" name="HTTP/1.x" stroke={protocolColors.http} strokeWidth={2} fill="url(#m-fill-http)" isAnimationActive={false} />
                <Area type="monotone" dataKey="https_rps" name="HTTPS" stroke={protocolColors.https} strokeWidth={2} fill="url(#m-fill-https)" isAnimationActive={false} />
                <Area type="monotone" dataKey="h3_rps" name="HTTP/3" stroke={protocolColors.h3} strokeWidth={2} fill="url(#m-fill-h3)" isAnimationActive={false} />
                <Area type="monotone" dataKey="grpc_rps" name="gRPC" stroke={protocolColors.grpc} strokeWidth={2} fill="url(#m-fill-grpc)" isAnimationActive={false} />
              </AreaChart>
            </ResponsiveContainer>
          </div>
        )}
        {ratesAllNearZero && requestsTrend.length > 0 && (
          <p className={styles.chartHint}>
            Lines are at zero: no proxied request rate in this window, or counters are unchanged between samples. HTTP/3
            load (e.g. k6 http3) appears on the HTTP/3 and Total lines — not under HTTPS.
          </p>
        )}
      </Panel>

      <div className={styles.twoCol}>
        <Panel
          title="Network throughput"
          description="Bytes sent and received per second (KiB/s)"
          actions={
            <Legend
              items={[
                { label: 'Sent', color: chartColors.c3 },
                { label: 'Received', color: chartColors.c2 },
              ]}
            />
          }
        >
          {throughputTrend.length === 0 ? (
            <ChartEmpty message={emptyMsg} height={200} />
          ) : (
            <div className={styles.chartBoxSm}>
              <ResponsiveContainer width="100%" height="100%">
                <AreaChart data={throughputTrend} margin={chartMargin}>
                  <defs>
                    <GradientDef id="m-fill-sent" color={chartColors.c3} />
                    <GradientDef id="m-fill-recv" color={chartColors.c2} opacity={0.3} />
                  </defs>
                  <CartesianGrid {...chartGridProps} />
                  <XAxis dataKey="tMs" {...timeAxis} />
                  <YAxis {...chartAxisProps} width={52} domain={topDomain(0.5, 1.2)} tickFormatter={(v) => formatChartNumber(Number(v))} />
                  <Tooltip
                    content={
                      <ChartTooltip
                        labelFormatter={formatChartTooltipXLabel}
                        valueFormatter={(v) => `${v.toFixed(2)} KiB/s`}
                      />
                    }
                  />
                  <Area type="monotone" dataKey="sent_kibps" name="Sent" stroke={chartColors.c3} strokeWidth={2} fill="url(#m-fill-sent)" isAnimationActive={false} />
                  <Area type="monotone" dataKey="recv_kibps" name="Received" stroke={chartColors.c2} strokeWidth={2} fill="url(#m-fill-recv)" isAnimationActive={false} />
                </AreaChart>
              </ResponsiveContainer>
            </div>
          )}
          {tpAllNearZero && throughputTrend.length > 0 && (
            <p className={styles.chartHint}>
              Throughput is zero in this window: no proxied traffic with bodies, or only tiny responses. Counts include
              request/response body bytes through the TCP proxy and HTTP/3 gateway (not headers, WebSocket streams, or
              management API JSON).
            </p>
          )}
        </Panel>

        <Panel
          title="CPU & memory"
          description="Erlang VM process usage"
          actions={
            <Legend
              items={[
                ...(hasCpu ? [{ label: 'CPU %', color: chartColors.c4 }] : []),
                ...(hasMemory ? [{ label: 'Memory (MiB)', color: chartColors.c1 }] : []),
              ]}
            />
          }
        >
          {history.length === 0 || (!hasCpu && !hasMemory) ? (
            <ChartEmpty message={history.length === 0 ? emptyMsg : 'No process CPU/memory data reported.'} height={200} />
          ) : (
            <div className={styles.chartBoxSm}>
              <ResponsiveContainer width="100%" height="100%">
                <AreaChart data={history} margin={{ ...chartMargin, right: 0 }}>
                  <defs>
                    <GradientDef id="m-fill-cpu" color={chartColors.c4} />
                    <GradientDef id="m-fill-mem" color={chartColors.c1} />
                  </defs>
                  <CartesianGrid {...chartGridProps} />
                  <XAxis dataKey="t" {...timeAxis} />
                  <YAxis yAxisId="left" {...chartAxisProps} width={44} domain={topDomain(4)} tickFormatter={(v) => `${formatChartNumber(Number(v))}%`} />
                  <YAxis yAxisId="right" orientation="right" {...chartAxisProps} width={52} domain={topDomain(16, 1.1)} tickFormatter={(v) => formatChartNumber(Number(v))} />
                  <Tooltip
                    content={
                      <ChartTooltip
                        labelFormatter={formatChartTooltipXLabel}
                        valueFormatter={(v, name) =>
                          name === 'CPU %'
                            ? `${v.toFixed(2)}% — ${formatPertiskVmCpuLine(v, latest?.logical_processors)}`
                            : `${v.toFixed(2)} MiB`
                        }
                      />
                    }
                  />
                  {hasCpu && (
                    <Area yAxisId="left" type="monotone" dataKey="cpu_percent" name="CPU %" stroke={chartColors.c4} strokeWidth={2} fill="url(#m-fill-cpu)" isAnimationActive={false} connectNulls />
                  )}
                  {hasMemory && (
                    <Area yAxisId="right" type="monotone" dataKey="memory_used_mb" name="Memory (MiB)" stroke={chartColors.c1} strokeWidth={2} fill="url(#m-fill-mem)" isAnimationActive={false} connectNulls />
                  )}
                </AreaChart>
              </ResponsiveContainer>
            </div>
          )}
        </Panel>
      </div>

      <Panel
        title="Connections & log buffer"
        description="Active upstream connections and in-memory log entries"
        actions={
          <Legend
            items={[
              { label: 'Active connections', color: chartColors.c2 },
              { label: 'Log entries', color: chartColors.c5 },
            ]}
          />
        }
      >
        {history.length === 0 ? (
          <ChartEmpty message={emptyMsg} height={180} />
        ) : (
          <div className={styles.chartBoxSm}>
            <ResponsiveContainer width="100%" height="100%">
              <AreaChart data={history} margin={{ ...chartMargin, right: 0 }}>
                <defs>
                  <GradientDef id="m-fill-conn" color={chartColors.c2} />
                  <GradientDef id="m-fill-log" color={chartColors.c5} opacity={0.25} />
                </defs>
                <CartesianGrid {...chartGridProps} />
                <XAxis dataKey="t" {...timeAxis} />
                <YAxis yAxisId="left" {...chartAxisProps} width={44} allowDecimals={false} domain={topDomain(4)} tickFormatter={(v) => formatChartNumber(Number(v))} />
                <YAxis yAxisId="right" orientation="right" {...chartAxisProps} width={52} allowDecimals={false} domain={topDomain(16, 1.1)} tickFormatter={(v) => formatChartNumber(Number(v))} />
                <Tooltip content={<ChartTooltip labelFormatter={formatChartTooltipXLabel} valueFormatter={(v) => Math.round(v).toLocaleString()} />} />
                <Area yAxisId="left" type="monotone" dataKey="active_connections" name="Active connections" stroke={chartColors.c2} strokeWidth={2} fill="url(#m-fill-conn)" isAnimationActive={false} />
                <Area yAxisId="right" type="monotone" dataKey="log_entries" name="Log entries" stroke={chartColors.c5} strokeWidth={2} fill="url(#m-fill-log)" isAnimationActive={false} />
              </AreaChart>
            </ResponsiveContainer>
          </div>
        )}
      </Panel>

      <div className={styles.twoCol}>
        <Panel title="HTTP/2 vs HTTP/3" description="Cumulative request split since process start">
          {h2h3Pie.length === 0 ? (
            <ChartEmpty message="No H2/H3 requests yet." height={220} />
          ) : (
            <div className={styles.pieWrap}>
              <ResponsiveContainer width="100%" height={220}>
                <PieChart>
                  <Pie
                    data={h2h3Pie}
                    dataKey="value"
                    nameKey="name"
                    innerRadius={58}
                    outerRadius={88}
                    paddingAngle={2}
                    strokeWidth={0}
                    isAnimationActive={false}
                  >
                    {h2h3Pie.map((entry) => (
                      <Cell key={entry.name} fill={entry.color} />
                    ))}
                  </Pie>
                  <Tooltip content={<ChartTooltip />} />
                </PieChart>
              </ResponsiveContainer>
              <div className={styles.pieCenter}>
                <span className={styles.pieTotal}>{h3Share != null ? `${h3Share.toFixed(1)}%` : '—'}</span>
                <span className={styles.pieCaption}>HTTP/3 share</span>
              </div>
            </div>
          )}
          <ul className={styles.pieLegend}>
            <li className={styles.pieLegendItem}>
              <span className={styles.pieLegendName}>
                <span className={styles.legendDot} style={{ background: protocolColors.h2 }} />
                HTTP/2
              </span>
              <span className={styles.mono}>{h2Total.toLocaleString()}</span>
            </li>
            <li className={styles.pieLegendItem}>
              <span className={styles.pieLegendName}>
                <span className={styles.legendDot} style={{ background: protocolColors.h3 }} />
                HTTP/3
              </span>
              <span className={styles.mono}>{h3Total.toLocaleString()}</span>
            </li>
          </ul>
        </Panel>

        <Panel
          title="Per-site H2 / H3"
          description={`Top ${TOP_SITES} hosts by request count`}
          actions={
            <Legend
              items={[
                { label: 'H2', color: protocolColors.h2 },
                { label: 'H3', color: protocolColors.h3 },
              ]}
            />
          }
        >
          {siteBars.length === 0 ? (
            <ChartEmpty message="No per-site H2/H3 counters yet." height={220} />
          ) : (
            <div style={{ height: Math.max(220, siteBars.length * 32 + 40) }}>
              <ResponsiveContainer width="100%" height="100%">
                <BarChart data={siteBars} layout="vertical" margin={{ left: 0, right: 16, top: 4, bottom: 0 }}>
                  <CartesianGrid {...chartGridProps} vertical horizontal={false} />
                  <XAxis type="number" {...chartAxisProps} allowDecimals={false} />
                  <YAxis
                    type="category"
                    dataKey="host"
                    {...chartAxisProps}
                    width={140}
                    tickFormatter={(v: string) => (v.length > 22 ? `${v.slice(0, 21)}…` : v)}
                  />
                  <Tooltip
                    cursor={{ fill: 'var(--color-hover)', opacity: 0.4 }}
                    content={<ChartTooltip labelFormatter={(l) => String(l)} />}
                  />
                  <Bar dataKey="h2" name="H2" stackId="p" fill={protocolColors.h2} isAnimationActive={false} />
                  <Bar dataKey="h3" name="H3" stackId="p" fill={protocolColors.h3} radius={[0, 3, 3, 0]} isAnimationActive={false} />
                </BarChart>
              </ResponsiveContainer>
            </div>
          )}
        </Panel>
      </div>

      {hostProtocolRows.length > 0 && (
        <Panel title="Ingress host protocol summary" description="Active connections and protocol counters by host" flush>
          <div className={styles.tableScroll}>
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
                    <td className={styles.mono}>{row.host}</td>
                    <td className={styles.mono}>{localeInt(row.activeConnections)}</td>
                    <td className={styles.mono}>{localeInt(row.h2)}</td>
                    <td className={styles.mono}>{localeInt(row.h3)}</td>
                    <td className={styles.mono}>{Number.isFinite(row.ratio) ? row.ratio.toFixed(3) : '—'}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </Panel>
      )}

      <Panel>
        <PrometheusScrapePanel management={management} compact />
      </Panel>
    </div>
  );
}
