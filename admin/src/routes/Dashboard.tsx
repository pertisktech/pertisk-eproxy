import { useEffect, useState, useCallback, useMemo, useRef, type ReactNode } from 'react';
import { Link } from 'react-router-dom';
import { ArrowUpRight, Cpu, ListTree, MemoryStick, RefreshCw } from 'lucide-react';
import {
  api,
  openRealtimeStream,
  type CertificateRow,
  type HealthReport,
  type ProxyConfig,
  type ManagementInfo,
  type Metrics,
  type K8sPodRow,
  type RealtimeSnapshot,
} from '@/api/client';
import {
  beamCpuShareOfHostCpusPercent,
  formatContainerCpuLine,
  formatPertiskVmCpuLine,
  containerCpuTooltip,
  pertiskVmCpuTooltip,
} from '@/utils/beamCpu';
import {
  buildTlsSiteValidationRows,
  tlsValidationDetail,
  tlsValidationResultLabel,
} from '@/utils/tlsSiteValidation';
import PrometheusScrapePanel from '@/components/PrometheusScrapePanel';
import HealthProbesPanel from '@/components/HealthProbesPanel';
import {
  BandwidthChart,
  ChartEmpty,
  ChartLegend,
  Meter,
  PageHeader,
  Panel,
  RequestsChart,
  ShareDonut,
  StatCard,
  StatusBadge,
  StatusDot,
  protocolColors,
  type BandwidthPoint,
  type RequestPoint,
} from '@/components/console';
import styles from './Dashboard.module.css';

const MAX_POINTS = 24;
/** Ignore samples closer together than this (poll + websocket can fire back to back). */
const MIN_SAMPLE_GAP_MS = 1500;

type DashboardCache = {
  config: ProxyConfig | null;
  health: HealthReport | null;
  management: ManagementInfo | null;
  stats: Metrics | null;
  issuedTlsCerts: CertificateRow[];
};

let dashboardCache: DashboardCache | null = null;

function formatBytes(n: number | undefined | null): string {
  if (n == null || !Number.isFinite(n) || n < 0) return '—';
  if (n < 1024) return `${n} B`;
  const kb = n / 1024;
  if (kb < 1024) return `${kb.toFixed(1)} KiB`;
  const mb = kb / 1024;
  if (mb < 1024) return `${mb.toFixed(1)} MiB`;
  return `${(mb / 1024).toFixed(2)} GiB`;
}

function formatBytesPerSec(bytesPerSec: number): string {
  if (!Number.isFinite(bytesPerSec) || bytesPerSec <= 0) return '0 B/s';
  if (bytesPerSec < 1024) return `${bytesPerSec.toFixed(0)} B/s`;
  if (bytesPerSec < 1024 * 1024) return `${(bytesPerSec / 1024).toFixed(1)} KiB/s`;
  if (bytesPerSec < 1024 * 1024 * 1024) return `${(bytesPerSec / (1024 * 1024)).toFixed(1)} MiB/s`;
  return `${(bytesPerSec / (1024 * 1024 * 1024)).toFixed(2)} GiB/s`;
}

function formatMillicores(millicores: number): string {
  return `${millicores}m`;
}

function formatTopMemory(bytes: number): string {
  if (bytes <= 0) return '0Mi';
  const mib = bytes / (1024 * 1024);
  if (mib < 1) {
    const kib = bytes / 1024;
    return `${Math.max(1, Math.round(kib))}Ki`;
  }
  if (mib < 1024) return `${Math.round(mib)}Mi`;
  return `${(mib / 1024).toFixed(1)}Gi`;
}

function formatUptime(secs: number | null | undefined): string {
  if (secs == null || !Number.isFinite(secs)) return '—';
  const total = Math.max(0, Math.floor(secs));
  const d = Math.floor(total / 86400);
  const h = Math.floor((total % 86400) / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  if (d > 0) return h > 0 ? `${d}d ${h}h` : `${d}d`;
  if (h > 0) return m > 0 ? `${h}h ${m}m` : `${h}h`;
  if (m > 0) return s > 0 && m < 10 ? `${m}m ${s}s` : `${m}m`;
  return `${s}s`;
}

function formatPercent(value: number | null): string {
  if (value == null || !Number.isFinite(value)) return '—';
  return `${value.toFixed(1)}%`;
}

function tickLabel(ts: number) {
  return new Date(ts).toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit', second: '2-digit' });
}

function deltaRate(curr: number, prev: number, seconds: number): number {
  if (seconds <= 0 || curr < prev) return 0;
  return (curr - prev) / seconds;
}

function InfoRow({
  label,
  value,
  mono = true,
  title,
}: {
  label: string;
  value: ReactNode;
  mono?: boolean;
  title?: string;
}) {
  return (
    <div className={styles.infoRow} title={title}>
      <dt className={styles.infoLabel}>{label}</dt>
      <dd className={`${styles.infoValue} ${mono ? styles.mono : ''}`}>{value}</dd>
    </div>
  );
}

export default function Dashboard() {
  const [config, setConfig] = useState<ProxyConfig | null>(() => dashboardCache?.config ?? null);
  const [health, setHealth] = useState<HealthReport | null>(() => dashboardCache?.health ?? null);
  const [management, setManagement] = useState<ManagementInfo | null>(() => dashboardCache?.management ?? null);
  const [stats, setStats] = useState<Metrics | null>(() => dashboardCache?.stats ?? null);
  const [k8sPods, setK8sPods] = useState<K8sPodRow[]>([]);
  const [issuedTlsCerts, setIssuedTlsCerts] = useState<CertificateRow[]>(
    () => dashboardCache?.issuedTlsCerts ?? [],
  );
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(() => dashboardCache == null);
  const [refreshing, setRefreshing] = useState(false);
  const [k8sLoading, setK8sLoading] = useState(false);
  const [requestSeries, setRequestSeries] = useState<RequestPoint[]>([]);
  const [bandwidthSeries, setBandwidthSeries] = useState<BandwidthPoint[]>([]);
  const [rates, setRates] = useState({ sent: 0, recv: 0 });
  const prevSample = useRef<{ m: Metrics; at: number } | null>(null);

  /** Turn successive counter snapshots into per-second rates (poll + realtime stream share this). */
  const ingestStats = useCallback((m: Metrics) => {
    const now = Date.now();
    const prev = prevSample.current;
    if (prev && now - prev.at < MIN_SAMPLE_GAP_MS) return;
    prevSample.current = { m, at: now };
    if (!prev) return;

    const secs = (now - prev.at) / 1000;
    const h2 = deltaRate(m.h2_requests_total ?? 0, prev.m.h2_requests_total ?? 0, secs);
    const h3 = deltaRate(m.h3_requests_total ?? 0, prev.m.h3_requests_total ?? 0, secs);
    const egress = deltaRate(m.bytes_sent_total ?? 0, prev.m.bytes_sent_total ?? 0, secs);
    const ingress = deltaRate(m.bytes_received_total ?? 0, prev.m.bytes_received_total ?? 0, secs);
    setRates({ sent: egress, recv: ingress });

    const label = tickLabel(now);
    setRequestSeries((series) =>
      [...series, { t: label, http2: Math.round(h2 * 10) / 10, http3: Math.round(h3 * 10) / 10 }].slice(-MAX_POINTS),
    );
    setBandwidthSeries((series) =>
      [
        ...series,
        {
          t: label,
          egress: Math.round((egress / (1024 * 1024)) * 100) / 100,
          ingress: Math.round((ingress / (1024 * 1024)) * 100) / 100,
        },
      ].slice(-MAX_POINTS),
    );
  }, []);

  const load = useCallback(
    async (opts?: { silent?: boolean }) => {
      const silent = opts?.silent === true;
      if (!silent) {
        setLoading(true);
      }
      setRefreshing(true);
      try {
        const [c, h, m, st, certList] = await Promise.all([
          api.config(),
          api.health(),
          api.management(),
          api.metrics(),
          api.certificates.list().catch(() => [] as CertificateRow[]),
        ]);
        const certs = Array.isArray(certList) ? certList : [];
        setConfig(c);
        setHealth(h);
        setManagement(m);
        setStats(st);
        setIssuedTlsCerts(certs);
        dashboardCache = { config: c, health: h, management: m, stats: st, issuedTlsCerts: certs };
        setError(null);
        ingestStats(st);
      } catch (e: unknown) {
        setError(String(e));
      } finally {
        setRefreshing(false);
        if (!silent) {
          setLoading(false);
        }
      }
    },
    [ingestStats],
  );

  useEffect(() => {
    void load({ silent: dashboardCache != null });
  }, [load]);

  useEffect(() => {
    const timer = window.setInterval(() => {
      if (document.visibilityState !== 'visible') return;
      void load({ silent: true });
    }, 10000);
    return () => window.clearInterval(timer);
  }, [load]);

  // Realtime stream: keeps stats/management fresh and feeds the live rate charts between polls.
  useEffect(() => {
    const stop = openRealtimeStream((snapshot: RealtimeSnapshot) => {
      setStats(snapshot.stats);
      setManagement(snapshot.management);
      ingestStats(snapshot.stats);
    });
    return stop;
  }, [ingestStats]);

  useEffect(() => {
    if (management?.mode !== 'ingress') return;
    let cancelled = false;

    async function loadK8s() {
      try {
        setK8sLoading(true);
        const pods = await api.kubernetes.pods();
        if (!cancelled) {
          setK8sPods(pods);
        }
      } catch {
        if (!cancelled) {
          setK8sPods([]);
        }
      } finally {
        if (!cancelled) {
          setK8sLoading(false);
        }
      }
    }
    void loadK8s();
    const t = setInterval(() => void loadK8s(), 10000);
    return () => {
      cancelled = true;
      clearInterval(t);
    };
  }, [management?.mode]);

  const isIngressMode = management?.mode === 'ingress';
  /** API returns controller replicas only (Helm app.kubernetes.io/name + instance labels). */
  const ingressPods = k8sPods;
  const leaderInfo = management?.leader_election ?? null;
  const leaderStatus = leaderInfo
    ? leaderInfo.enabled
      ? leaderInfo.is_leader
        ? 'Leader'
        : 'Standby'
      : 'Disabled'
    : null;

  const pi = management?.process_info;
  const listeners = Array.isArray(management?.listeners) ? management.listeners : [];
  const memBreakdown = pi?.memory_breakdown_bytes;
  const memBytes =
    management?.process_memory_bytes ??
    memBreakdown?.total ??
    (typeof pi?.memory_total_bytes === 'number' ? pi.memory_total_bytes : null);
  const codeMemBytes = typeof memBreakdown?.code === 'number' ? memBreakdown.code : null;
  const beamCpu = management?.process_cpu_usage_percent;
  const beamCpuOk = beamCpu != null && Number.isFinite(beamCpu);
  const selfPod =
    isIngressMode && pi?.hostname ? ingressPods.find((pod) => pod.name === pi.hostname) : undefined;
  const containerCpuMilli = selfPod?.cpu_usage_millicores;
  const containerCpuLimitMilli = selfPod?.cpu_limit_millicores ?? 1000;
  const containerCpuSummary =
    containerCpuMilli != null ? formatContainerCpuLine(containerCpuMilli, containerCpuLimitMilli) : null;
  const containerCpuPct =
    containerCpuMilli != null && containerCpuLimitMilli > 0
      ? (containerCpuMilli / containerCpuLimitMilli) * 100
      : null;
  const cpuMeterPct =
    containerCpuPct ??
    (beamCpuOk && pi?.logical_processors
      ? beamCpuShareOfHostCpusPercent(beamCpu, pi.logical_processors)
      : null);
  const cpuDetail =
    containerCpuSummary ?? (beamCpuOk ? formatPertiskVmCpuLine(beamCpu, pi?.logical_processors) : '—');
  const cpuTitle =
    containerCpuSummary != null
      ? containerCpuTooltip()
      : pertiskVmCpuTooltip(pi?.logical_processors, beamCpu);
  const cpuStatValue =
    containerCpuPct != null ? formatPercent(containerCpuPct) : beamCpuOk ? formatPercent(beamCpu) : '—';
  const processCount = typeof pi?.process_count === 'number' ? pi.process_count : null;
  const processLimit = typeof pi?.process_limit === 'number' ? pi.process_limit : null;
  const processUsagePct =
    processCount != null && processLimit != null && processLimit > 0
      ? (processCount / processLimit) * 100
      : null;
  const publicIp = [management?.public_ipv4, management?.public_ipv6].filter(Boolean).join(' · ');

  const tlsSiteRows = useMemo(
    () => buildTlsSiteValidationRows(config?.sites ?? [], health, issuedTlsCerts),
    [config?.sites, health, issuedTlsCerts],
  );
  const siteCount = config?.sites?.length ?? 0;
  const backendCount = config?.backends?.length ?? 0;

  const healthOk = useMemo(() => {
    const rows = health?.backends ?? [];
    if (rows.length === 0) return true;
    return rows.every((b) => b.total === 0 || b.healthy >= b.total);
  }, [health?.backends]);

  const h2Total = stats?.h2_requests_total ?? 0;
  const h3Total = stats?.h3_requests_total ?? 0;
  const httpTotal = h2Total + h3Total;
  const h3Share = httpTotal > 0 ? (h3Total / httpTotal) * 100 : null;
  const shareData = [
    { name: 'HTTP/3', value: h3Total, color: protocolColors.h3 },
    { name: 'HTTP/2', value: h2Total, color: protocolColors.h2 },
  ];

  const busiestSites = useMemo(() => {
    const h2 = stats?.site_h2_requests_total ?? {};
    const h3 = stats?.site_h3_requests_total ?? {};
    return Array.from(new Set([...Object.keys(h2), ...Object.keys(h3)]))
      .map((host) => ({ host, count: (h2[host] ?? 0) + (h3[host] ?? 0) }))
      .filter((s) => s.count > 0)
      .sort((a, b) => b.count - a.count)
      .slice(0, 5);
  }, [stats?.site_h2_requests_total, stats?.site_h3_requests_total]);

  const busy = loading || refreshing;

  return (
    <section className={styles.page}>
      <PageHeader
        title="Dashboard"
        description="Live overview of the pertisk-eproxy runtime, traffic, and host health."
        actions={
          <>
            <StatusBadge tone={healthOk ? 'success' : 'warning'} pulse={healthOk}>
              uptime {formatUptime(stats?.uptime_secs)}
            </StatusBadge>
            <StatusBadge tone="muted" dot={false}>
              {management?.mode ?? 'proxy'} mode
            </StatusBadge>
            {health && !healthOk ? <StatusBadge tone="warning">Needs attention</StatusBadge> : null}
            <button
              type="button"
              className={styles.refreshBtn}
              onClick={() => void load()}
              disabled={busy}
              aria-busy={busy}
              title="Reload dashboard data"
            >
              <RefreshCw size={14} className={busy ? styles.spin : undefined} aria-hidden />
              Refresh
            </button>
          </>
        }
      />

      {error && (
        <div className="error-banner" role="alert">
          <i className="fas fa-exclamation-circle" aria-hidden />
          {error}
        </div>
      )}

      {loading ? (
        <div className={styles.loadingWrap}>
          <div className="spinner" />
        </div>
      ) : (
        <>
          <div className={styles.statGrid} role="group" aria-label="Dashboard summary">
            <StatCard label="Sites" value={String(siteCount)} hint={`${backendCount} backends`} />
            <StatCard label="Backends" value={String(backendCount)} hint={`${health?.backends?.length ?? 0} health-checked`} />
            <StatCard
              label="Active connections"
              value={(stats?.active_connections ?? 0).toLocaleString()}
              hint={`${formatBytes(stats?.bytes_sent_total)} sent`}
              title="In-flight requests to backend upstreams (not admin UI sessions). Often 0 when idle."
            />
            <StatCard
              label="Requests"
              value={httpTotal.toLocaleString()}
              hint={`H2 ${h2Total.toLocaleString()} · H3 ${h3Total.toLocaleString()}`}
            />
            <StatCard
              label="HTTP/3 share"
              value={h3Share != null ? `${h3Share.toFixed(1)}%` : '—'}
              hint={`${h3Total.toLocaleString()} of ${httpTotal.toLocaleString()} reqs`}
            />
            <StatCard label="Bytes sent" value={formatBytesPerSec(rates.sent)} hint="egress rate" />
            <StatCard label="Bytes received" value={formatBytesPerSec(rates.recv)} hint="ingress rate" />
            <StatCard
              label="Memory"
              value={memBytes != null ? formatBytes(memBytes) : '—'}
              hint={codeMemBytes != null ? `code ${formatBytes(codeMemBytes)}` : `CPU ${cpuStatValue}`}
              title="erlang:memory(total) — VM allocated memory."
            />
          </div>

          <div className={styles.threeCol}>
            <Panel
              title="Request throughput"
              description="HTTP/2 vs HTTP/3 requests per second"
              className={styles.span2}
              actions={
                <ChartLegend
                  items={[
                    { label: 'HTTP/3', color: protocolColors.h3 },
                    { label: 'HTTP/2', color: protocolColors.h2 },
                  ]}
                />
              }
            >
              {requestSeries.length > 0 ? (
                <RequestsChart data={requestSeries} />
              ) : (
                <ChartEmpty message="Collecting live samples…" height={240} />
              )}
            </Panel>

            <Panel title="Protocol share" description="HTTP/2 vs HTTP/3 since process start">
              {httpTotal > 0 ? (
                <ShareDonut
                  data={shareData}
                  centerValue={h3Share != null ? `${h3Share.toFixed(1)}%` : '—'}
                  centerLabel="HTTP/3"
                />
              ) : (
                <ChartEmpty message="No H2/H3 requests yet." height={220} />
              )}
              <ul className={styles.shareList}>
                {shareData.map((s) => (
                  <li key={s.name} className={styles.shareItem}>
                    <span className={styles.shareName}>
                      <span className={styles.shareDot} style={{ background: s.color }} />
                      {s.name}
                    </span>
                    <span className={styles.mono}>{s.value.toLocaleString()}</span>
                  </li>
                ))}
              </ul>
            </Panel>
          </div>

          <div className={styles.threeCol}>
            {!isIngressMode ? (
              <Panel title="Host system" description={`${pi?.hostname ?? 'host'} · ${pi?.os_type ?? 'unknown OS'}`} bodyClassName={styles.stack}>
                <Meter
                  label="CPU"
                  detail={cpuDetail}
                  pct={cpuMeterPct}
                  icon={<Cpu size={16} aria-hidden />}
                  title={cpuTitle}
                />
                <Meter
                  label="Memory"
                  detail={memBytes != null ? `${formatBytes(memBytes)} allocated` : '—'}
                  pct={null}
                  icon={<MemoryStick size={16} aria-hidden />}
                  title="erlang:memory(total) — total allocated by the runtime."
                />
                <Meter
                  label="Processes"
                  detail={
                    processCount != null && processLimit != null
                      ? `${processCount.toLocaleString()} / ${processLimit.toLocaleString()}`
                      : '—'
                  }
                  pct={processUsagePct}
                  icon={<ListTree size={16} aria-hidden />}
                />
                <dl className={styles.infoList}>
                  <InfoRow label="Node" value={pi?.node ?? '—'} />
                  <InfoRow label="OTP / ERTS" value={`${pi?.otp_release ?? '—'} / ${pi?.erts_version ?? '—'}`} />
                  <InfoRow
                    label="Schedulers"
                    value={pi?.schedulers != null ? `${pi.schedulers} · ${pi.logical_processors ?? '—'} CPUs` : '—'}
                  />
                  <InfoRow label="Public IP" value={publicIp || '—'} title={management?.public_ip_error ?? undefined} />
                  <InfoRow label="Database" value={management?.db_path ?? '—'} />
                </dl>
              </Panel>
            ) : (
              <Panel title="Controller" description="Ingress runtime" bodyClassName={styles.stack}>
                <dl className={styles.infoList}>
                  <InfoRow label="Hostname" value={pi?.hostname ?? '—'} />
                  <InfoRow label="OS PID" value={pi?.os_pid ?? '—'} />
                  <InfoRow label="Node" value={pi?.node ?? '—'} />
                  <InfoRow label="OTP / ERTS" value={`${pi?.otp_release ?? '—'} / ${pi?.erts_version ?? '—'}`} />
                  <InfoRow
                    label="Leader"
                    value={
                      leaderInfo && leaderStatus
                        ? `${leaderStatus} (${leaderInfo.namespace}/${leaderInfo.lease_name})`
                        : 'n/a'
                    }
                  />
                  <InfoRow label="Public IP" value={publicIp || '—'} title={management?.public_ip_error ?? undefined} />
                </dl>
                <Meter label="CPU" detail={cpuDetail} pct={cpuMeterPct} icon={<Cpu size={16} aria-hidden />} title={cpuTitle} />
                <div className={styles.podBlock}>
                  <p className={styles.podCount}>
                    {k8sLoading ? 'Loading pods…' : `${ingressPods.length} pod${ingressPods.length === 1 ? '' : 's'}`}
                  </p>
                  <ul className={styles.podList}>
                    {ingressPods.length === 0 ? (
                      <li className={styles.podEmpty}>{k8sLoading ? 'Loading…' : 'No ingress pods found'}</li>
                    ) : (
                      ingressPods.slice(0, 4).map((pod) => (
                        <li key={`${pod.namespace}/${pod.name}`} className={styles.podRow}>
                          <span className={`${styles.mono} ${styles.podName}`} title={pod.name}>
                            {pod.name}
                          </span>
                          <span className={styles.podMeta}>
                            {pod.ready}
                            {pod.cpu_usage_millicores != null ? ` · ${formatMillicores(pod.cpu_usage_millicores)}` : ''}
                            {pod.memory_usage_bytes != null ? ` · ${formatTopMemory(pod.memory_usage_bytes)}` : ''}
                          </span>
                        </li>
                      ))
                    )}
                  </ul>
                </div>
              </Panel>
            )}

            <Panel
              title="Bandwidth"
              description="Ingress vs egress rate (MB/s)"
              actions={
                <ChartLegend
                  items={[
                    { label: 'Egress', color: 'var(--color-chart-1)' },
                    { label: 'Ingress', color: 'var(--color-chart-2)' },
                  ]}
                />
              }
            >
              {bandwidthSeries.length > 0 ? (
                <BandwidthChart data={bandwidthSeries} unit="MB/s" />
              ) : (
                <ChartEmpty message="Collecting live samples…" height={240} />
              )}
            </Panel>

            <Panel
              title="Busiest sites"
              description="By H2 + H3 request volume"
              flush
              actions={
                <Link to="/sites" className={styles.panelLink}>
                  All sites <ArrowUpRight size={12} aria-hidden />
                </Link>
              }
            >
              {busiestSites.length === 0 ? (
                <p className={styles.emptyNote}>No traffic yet</p>
              ) : (
                <ul className={styles.siteList}>
                  {busiestSites.map((site) => (
                    <li key={site.host} className={styles.siteRow}>
                      <span className={styles.siteHost}>
                        <StatusDot tone="success" />
                        <span className={`${styles.mono} ${styles.siteName}`} title={site.host}>
                          {site.host}
                        </span>
                      </span>
                      <span className={styles.siteCount}>{site.count.toLocaleString()}</span>
                    </li>
                  ))}
                </ul>
              )}
            </Panel>
          </div>

          {isIngressMode ? (
            <Panel
              title="Kubernetes runtime"
              description="Ingress controller replicas in the release namespace (refreshes every 10s)"
              actions={
                <StatusBadge tone="muted" dot={false}>
                  {k8sLoading ? 'Loading…' : `${ingressPods.length} pods`}
                </StatusBadge>
              }
              flush
            >
              <div className={styles.tableScroll}>
                <table className={styles.table}>
                  <thead>
                    <tr>
                      <th>Name</th>
                      <th>Namespace</th>
                      <th>Phase</th>
                      <th>Ready</th>
                      <th>Restarts</th>
                      <th>CPU</th>
                      <th>Memory</th>
                      <th>Pod IP</th>
                      <th>Node</th>
                    </tr>
                  </thead>
                  <tbody>
                    {ingressPods.map((pod) => (
                      <tr key={`${pod.namespace}/${pod.name}`}>
                        <td className={`${styles.mono} ${styles.nameCell}`} title={pod.name}>
                          {pod.name}
                        </td>
                        <td className={styles.mono}>{pod.namespace}</td>
                        <td>{pod.phase}</td>
                        <td className={styles.mono}>{pod.ready}</td>
                        <td className={styles.mono}>{pod.restarts ?? 0}</td>
                        <td className={styles.mono}>
                          {pod.cpu_usage_millicores != null ? formatMillicores(pod.cpu_usage_millicores) : 'n/a'}
                        </td>
                        <td className={styles.mono}>
                          {pod.memory_usage_bytes != null ? formatTopMemory(pod.memory_usage_bytes) : 'n/a'}
                        </td>
                        <td className={styles.mono}>{pod.pod_ip ?? 'n/a'}</td>
                        <td className={styles.mono}>{pod.node_name ?? pod.node ?? 'n/a'}</td>
                      </tr>
                    ))}
                    {ingressPods.length === 0 ? (
                      <tr>
                        <td colSpan={9} className={styles.emptyCell}>
                          {k8sLoading ? 'Loading pods…' : 'No ingress pods found'}
                        </td>
                      </tr>
                    ) : null}
                  </tbody>
                </table>
              </div>
            </Panel>
          ) : null}

          <Panel title="Listeners & ports" description="Bound services for this node" flush>
            <div className={styles.tableScroll}>
              <table className={styles.table}>
                <thead>
                  <tr>
                    <th>Service</th>
                    <th>Proto</th>
                    <th>Bind</th>
                    <th>Port</th>
                    <th>TLS</th>
                    <th>Stack</th>
                  </tr>
                </thead>
                <tbody>
                  {listeners.length === 0 ? (
                    <tr>
                      <td colSpan={6} className={styles.emptyCell}>
                        No listener metadata
                      </td>
                    </tr>
                  ) : (
                    listeners.map((L) => (
                      <tr key={L.id}>
                        <td>
                          <span className={styles.svcId}>{L.id}</span>
                          <div className={styles.svcDesc}>{L.description}</div>
                        </td>
                        <td className={styles.mono}>{L.protocol}</td>
                        <td className={styles.mono}>{L.bind}</td>
                        <td className={styles.mono}>{L.port}</td>
                        <td>{L.tls ? 'yes' : 'no'}</td>
                        <td>{L.stack}</td>
                      </tr>
                    ))
                  )}
                </tbody>
              </table>
            </div>
          </Panel>

          <Panel>
            <PrometheusScrapePanel management={management} />
          </Panel>

          <Panel>
            <HealthProbesPanel />
          </Panel>

          <Panel
            title="Site TLS validation"
            description="Hostname versus assigned certificate SAN/wildcard coverage."
            flush
          >
            <div className={styles.tableScroll}>
              <table className={styles.table}>
                <thead>
                  <tr>
                    <th>Host</th>
                    <th>Result</th>
                    <th>Detail</th>
                  </tr>
                </thead>
                <tbody>
                  {tlsSiteRows.length === 0 ? (
                    <tr>
                      <td colSpan={3} className={styles.emptyCell}>
                        {siteCount === 0
                          ? 'No sites configured — add a site under Sites to validate TLS coverage.'
                          : 'No TLS validation rows for configured sites. Try Refresh or check Certificates.'}
                      </td>
                    </tr>
                  ) : (
                    tlsSiteRows.map((row) => {
                      const result = tlsValidationResultLabel(row);
                      const tone =
                        result === 'match'
                          ? 'success'
                          : result === 'mismatch'
                            ? 'danger'
                            : result === 'pending'
                              ? 'warning'
                              : 'muted';
                      return (
                        <tr key={row.host}>
                          <td className={styles.mono}>{row.host}</td>
                          <td>
                            <StatusBadge tone={tone}>{result}</StatusBadge>
                          </td>
                          <td className={styles.mono}>{tlsValidationDetail(row)}</td>
                        </tr>
                      );
                    })
                  )}
                </tbody>
              </table>
            </div>
          </Panel>
        </>
      )}
    </section>
  );
}
