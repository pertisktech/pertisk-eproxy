import { useEffect, useState, useCallback } from 'react';
import { Link } from 'react-router-dom';
import {
  api,
  type BeamMemoryBreakdown,
  type HealthReport,
  type ProxyConfig,
  type ManagementInfo,
  type Metrics,
  type K8sPodRow,
} from '@/api/client';
import { formatBeamCpuPct, formatContainerCpuLine, formatPertiskVmCpuLine, containerCpuTooltip, pertiskVmCpuTooltip } from '@/utils/beamCpu';
import PrometheusScrapePanel from '@/components/PrometheusScrapePanel';
import HealthProbesPanel from '@/components/HealthProbesPanel';
import styles from './Dashboard.module.css';

type DashboardCache = {
  config: ProxyConfig | null;
  health: HealthReport | null;
  management: ManagementInfo | null;
  stats: Metrics | null;
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

const MEMORY_BREAKDOWN_ROWS: { key: keyof BeamMemoryBreakdown; label: string; hint?: string }[] = [
  { key: 'code', label: 'Code', hint: 'Erlang modules loaded in the VM (often higher in release embedded mode).' },
  { key: 'processes', label: 'Processes' },
  { key: 'system', label: 'System' },
  { key: 'binary', label: 'Binary' },
  { key: 'ets', label: 'ETS' },
  { key: 'atom', label: 'Atom' },
];

function formatTs(ms: number | null | undefined): string {
  if (ms == null || !Number.isFinite(ms)) return '—';
  try {
    return new Date(ms).toLocaleString();
  } catch {
    return String(ms);
  }
}

function formatPercent(value: number | null): string {
  if (value == null || !Number.isFinite(value)) return '—';
  return `${value.toFixed(1)}%`;
}

export default function Dashboard() {
  const [config, setConfig] = useState<ProxyConfig | null>(() => dashboardCache?.config ?? null);
  const [health, setHealth] = useState<HealthReport | null>(() => dashboardCache?.health ?? null);
  const [management, setManagement] = useState<ManagementInfo | null>(() => dashboardCache?.management ?? null);
  const [stats, setStats] = useState<Metrics | null>(() => dashboardCache?.stats ?? null);
  const [k8sPods, setK8sPods] = useState<K8sPodRow[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(() => dashboardCache == null);
  const [k8sLoading, setK8sLoading] = useState(false);

  const load = useCallback(async (opts?: { silent?: boolean }) => {
    const silent = opts?.silent === true;
    if (!silent) {
      setLoading(true);
    }
    try {
      const [c, h, m, st] = await Promise.all([
        api.config(),
        api.health(),
        api.management(),
        api.metrics(),
      ]);
      setConfig(c);
      setHealth(h);
      setManagement(m);
      setStats(st);
      dashboardCache = { config: c, health: h, management: m, stats: st };
      setError(null);
    } catch (e: unknown) {
      setError(String(e));
    } finally {
      if (!silent) {
        setLoading(false);
      }
    }
  }, []);

  useEffect(() => {
    void load({ silent: dashboardCache != null });
  }, [load]);

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
  const selfPod =
    isIngressMode && pi?.hostname
      ? ingressPods.find((pod) => pod.name === pi.hostname)
      : undefined;
  const containerCpuMilli = selfPod?.cpu_usage_millicores;
  const containerCpuLimitMilli = selfPod?.cpu_limit_millicores ?? 1000;
  const containerCpuSummary =
    containerCpuMilli != null && containerCpuLimitMilli != null
      ? formatContainerCpuLine(containerCpuMilli, containerCpuLimitMilli)
      : null;
  const cpuSummary =
    containerCpuSummary ??
    (beamCpu != null && Number.isFinite(beamCpu) ? formatBeamCpuPct(beamCpu) : null);
  const cpuSummarySub =
    containerCpuSummary != null
      ? 'metrics-server (this pod)'
      : beamCpu != null && Number.isFinite(beamCpu)
        ? formatPertiskVmCpuLine(beamCpu, pi?.logical_processors)
        : null;
  const cpuTileTitle =
    containerCpuSummary != null
      ? containerCpuTooltip()
      : pertiskVmCpuTooltip(pi?.logical_processors);
  const processCount = typeof pi?.process_count === 'number' ? pi.process_count : null;
  const processLimit = typeof pi?.process_limit === 'number' ? pi.process_limit : null;
  const processUsagePct =
    processCount != null && processLimit != null && processLimit > 0
      ? (processCount / processLimit) * 100
      : null;
  const runtimePorts = listeners
    .filter((l) => Number.isFinite(l.port) && l.port > 0)
    .sort((a, b) => a.port - b.port);
  const tlsSiteRows = Array.isArray(health?.tls_sites) ? health.tls_sites : [];

  return (
    <section className={styles.page}>
      {error && (
        <div className="error-banner" role="alert">
          <i className="fas fa-exclamation-circle" aria-hidden />
          {error}
        </div>
      )}

      <div className={styles.hero}>
        <div>
          <h1 className={styles.heroTitle}>Dashboard</h1>
          <p className={styles.heroSubtitle}>Operational snapshot of runtime health, traffic, and proxy readiness.</p>
        </div>
        <div className={styles.heroMeta}>
          <button
            type="button"
            className={styles.heroRefresh}
            onClick={() => void load()}
            disabled={loading}
            aria-busy={loading}
            title="Reload dashboard data"
          >
            <i className={`fas fa-sync-alt ${loading ? styles.heroRefreshSpin : ''}`} aria-hidden /> Refresh
          </button>
          <Link to="/metrics" className={styles.metricsLink}>
            <i className="fas fa-chart-line" aria-hidden /> Metrics
          </Link>
        </div>
      </div>

      {loading ? (
        <div className={styles.loadingWrap}>
          <div className="spinner" />
        </div>
      ) : (
        <>
          <div className={styles.glance}>
            <div className={styles.glanceMetrics} role="group" aria-label="Dashboard summary">
              <div
                className={`${styles.metricTile} ${styles.metricTileResource}`}
                title={cpuTileTitle}
              >
                <div className={styles.metricTileVal}>{cpuSummary ?? '—'}</div>
                <div className={styles.metricTileLabel}>CPU usage</div>
                {cpuSummarySub ? <div className={styles.metricTileSub}>{cpuSummarySub}</div> : null}
              </div>
              <div
                className={`${styles.metricTile} ${styles.metricTileResource}`}
                title={
                  'erlang:memory(total) — VM allocated memory. Code is Erlang bytecode in RAM; release embedded mode preloads modules and can use more code memory than dev.'
                }
              >
                <div className={styles.metricTileVal}>{memBytes != null ? formatBytes(memBytes) : '—'}</div>
                <div className={styles.metricTileLabel}>Memory usage</div>
                {codeMemBytes != null ? (
                  <div className={styles.metricTileSub}>code {formatBytes(codeMemBytes)}</div>
                ) : null}
              </div>
              <div className={styles.metricTile}>
                <div className={styles.metricTileVal}>{config?.sites?.length ?? 0}</div>
                <div className={styles.metricTileLabel}>Total sites</div>
              </div>
              <div className={styles.metricTile}>
                <div className={styles.metricTileVal}>{config?.backends?.length ?? 0}</div>
                <div className={styles.metricTileLabel}>Total backends</div>
              </div>
              <div className={styles.metricTile}>
                <div className={styles.metricTileVal}>{(stats?.http_requests_total ?? 0).toLocaleString()}</div>
                <div className={styles.metricTileLabel}>Total visits</div>
              </div>
              <div
                className={`${styles.metricTile} ${styles.metricTileHint}`}
                title="In-flight requests to backend upstreams (not admin UI sessions). Often 0 when idle."
              >
                <div className={styles.metricTileVal}>{stats?.active_connections ?? 0}</div>
                <div className={styles.metricTileLabel}>Pageviews</div>
              </div>
            </div>

            <div className={styles.glanceBottom}>
              <div className={`card ${styles.panel}`}>
                <h2 className={styles.panelTitle}>
                  <i className="fas fa-memory" aria-hidden /> VM resources
                </h2>
                <dl className={styles.kv}>
                  <dt>CPU</dt>
                  <dd title={cpuTileTitle}>
                    {containerCpuSummary != null ? (
                      <>
                        <div>{containerCpuSummary}</div>
                        <div className={styles.kvMuted}>metrics-server (this pod)</div>
                        {beamCpu != null && Number.isFinite(beamCpu) ? (
                          <div className={styles.kvMuted}>
                            BEAM scheduler sample: {formatBeamCpuPct(beamCpu)} —{' '}
                            {formatPertiskVmCpuLine(beamCpu, pi?.logical_processors)}
                          </div>
                        ) : null}
                      </>
                    ) : beamCpu != null && Number.isFinite(beamCpu) ? (
                      <>
                        <div>{formatPertiskVmCpuLine(beamCpu, pi?.logical_processors)}</div>
                        <div className={styles.kvMuted}>Scheduler sample (internal): {formatBeamCpuPct(beamCpu)}</div>
                      </>
                    ) : (
                      '—'
                    )}
                  </dd>
                  <dt>Memory (total)</dt>
                  <dd title="erlang:memory(total) — total allocated by the runtime.">
                    {memBytes != null ? `${formatBytes(memBytes)} allocated` : '—'}
                  </dd>
                  {MEMORY_BREAKDOWN_ROWS.map(({ key, label, hint }) => {
                    const n = memBreakdown?.[key];
                    if (n == null || !Number.isFinite(n)) return null;
                    return (
                      <span key={key} className={styles.kvBreakdownPair}>
                        <dt title={hint}>{label}</dt>
                        <dd title={hint}>{formatBytes(n)}</dd>
                      </span>
                    );
                  })}
                </dl>
              </div>

              <div className={`card ${styles.panel}`}>
                <h2 className={styles.panelTitle}>
                  <i className="fas fa-plug" aria-hidden /> Runtime
                </h2>
                <dl className={styles.kv}>
                  <dt>Hostname</dt>
                  <dd className="mono">{pi?.hostname ?? '—'}</dd>
                  <dt>Node</dt>
                  <dd className="mono">{pi?.node ?? '—'}</dd>
                  <dt>Runtime process</dt>
                  <dd className="mono">{pi?.os_pid ?? '—'}</dd>
                  <dt>BEAM processes</dt>
                  <dd>
                    {processCount != null && processLimit != null
                      ? `${processCount} / ${processLimit} (${formatPercent(processUsagePct)})`
                      : '—'}
                  </dd>
                  <dt>Ports</dt>
                  <dd>
                    {runtimePorts.length === 0 ? (
                      '—'
                    ) : (
                      <div className={styles.portBadgeWrap}>
                        {runtimePorts.map((listener) => (
                          <span key={listener.id} className={styles.portBadge}>
                            <span className={styles.portProto}>{listener.protocol.toUpperCase()}</span>
                            <span className="mono">:{listener.port}</span>
                          </span>
                        ))}
                      </div>
                    )}
                  </dd>
                  {health?.acme?.lego_required === false ? null : (
                    <>
                      <dt>Lego DNS CLI</dt>
                      <dd className="mono">
                        {health?.acme?.lego_installed
                          ? `Installed${health?.acme?.lego_path ? ` (${health.acme.lego_path})` : ''}`
                          : 'Not installed'}
                      </dd>
                    </>
                  )}
                </dl>
              </div>
            </div>
          </div>

          <div className={styles.twoCol}>
            <div className={`card ${styles.panel}`}>
              <h2 className={styles.panelTitle}>
                <i className="fas fa-microchip" aria-hidden /> System
              </h2>
              <dl className={styles.kv}>
                <dt>Hostname</dt>
                <dd className="mono">{pi?.hostname || '—'}</dd>
                <dt>OS</dt>
                <dd>
                  {pi?.os_type ?? '—'} {pi?.os_version ? `(${pi.os_version})` : ''}
                </dd>
                <dt>Architecture</dt>
                <dd className="mono">{pi?.system_architecture ?? '—'}</dd>
                {!isIngressMode ? (
                  <>
                    <dt>Database</dt>
                    <dd className="mono">{management?.db_path ?? '—'}</dd>
                  </>
                ) : null}
                {isIngressMode && leaderInfo && leaderStatus ? (
                  <>
                    <dt>Leader election</dt>
                    <dd className="mono">
                      {leaderStatus} ({leaderInfo.namespace}/{leaderInfo.lease_name})
                    </dd>
                  </>
                ) : null}
              </dl>
            </div>

            <div className={`card ${styles.panel}`}>
              <h2 className={styles.panelTitle}>
                <i className="fas fa-project-diagram" aria-hidden /> Process (BEAM)
              </h2>
              <dl className={styles.kv}>
                <dt>Node</dt>
                <dd className="mono">{pi?.node ?? '—'}</dd>
                <dt>OS PID</dt>
                <dd className="mono">{pi?.os_pid ?? '—'}</dd>
                <dt>OTP / ERTS</dt>
                <dd className="mono">
                  {pi?.otp_release ?? '—'} / {pi?.erts_version ?? '—'}
                </dd>
                <dt>Schedulers</dt>
                <dd>
                  {pi?.schedulers ?? '—'} ({pi?.logical_processors ?? '—'} logical CPUs,{' '}
                  {pi?.word_size ?? '—'}
                  -bit word)
                </dd>
                <dt>Processes</dt>
                <dd>
                  {pi?.process_count ?? '—'} / {pi?.process_limit ?? '—'}
                </dd>
                <dt>SMP / async threads</dt>
                <dd>
                  {pi?.smp_enabled === true ? 'yes' : pi?.smp_enabled === false ? 'no' : '—'} · pool{' '}
                  {pi?.thread_pool ?? '—'}
                </dd>
              </dl>
            </div>
          </div>

          {isIngressMode ? (
            <div className={`card ${styles.panel}`}>
              <h2 className={styles.panelTitle}>
                <i className="fas fa-diagram-project" aria-hidden /> Kubernetes runtime
              </h2>
              <p className={styles.panelHint}>
                All ingress controller replicas in the release namespace (refreshes every 10s)
              </p>
              <div className={styles.k8sHeader}>
                <span className={styles.k8sLabel}>Ingress pods</span>
                <span className={styles.k8sHint}>
                  {k8sLoading ? 'Loading…' : `${ingressPods.length} pods`}
                </span>
              </div>
              <div className={styles.k8sTableWrap}>
                <table className={styles.k8sTable}>
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
                        <td className={styles.k8sNameCell} title={pod.name}>
                          {pod.name}
                        </td>
                        <td>{pod.namespace}</td>
                        <td>{pod.phase}</td>
                        <td>{pod.ready}</td>
                        <td>{pod.restarts ?? 0}</td>
                        <td>
                          {pod.cpu_usage_millicores != null
                            ? formatMillicores(pod.cpu_usage_millicores)
                            : 'n/a'}
                        </td>
                        <td>
                          {pod.memory_usage_bytes != null
                            ? formatTopMemory(pod.memory_usage_bytes)
                            : 'n/a'}
                        </td>
                        <td>{pod.pod_ip ?? 'n/a'}</td>
                        <td>{pod.node_name ?? pod.node ?? 'n/a'}</td>
                      </tr>
                    ))}
                    {ingressPods.length === 0 ? (
                      <tr>
                        <td colSpan={9} className={styles.k8sEmpty}>
                          {k8sLoading ? 'Loading pods…' : 'No ingress pods found'}
                        </td>
                      </tr>
                    ) : null}
                  </tbody>
                </table>
              </div>
            </div>
          ) : null}

          <div className={`card ${styles.panel} ${styles.listenersPortsCard}`}>
            <h2 className={styles.panelTitle}>
              <i className="fas fa-plug" aria-hidden /> Listeners & ports
            </h2>
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
                        <td className="mono">{L.protocol}</td>
                        <td className="mono">{L.bind}</td>
                        <td className="mono">{L.port}</td>
                        <td>{L.tls ? 'yes' : 'no'}</td>
                        <td>{L.stack}</td>
                      </tr>
                    ))
                  )}
                </tbody>
              </table>
            </div>
          </div>

          <div className={`card ${styles.panel}`}>
            <PrometheusScrapePanel management={management} />
          </div>

          <div className={`card ${styles.panel}`}>
            <HealthProbesPanel />
          </div>

          <div className={`card ${styles.panel} ${styles.tlsValidationCard}`}>
            <h2 className={styles.panelTitle}>
              <i className="fas fa-shield-halved" aria-hidden /> Site TLS validation
            </h2>
            <p className={styles.panelHint}>Hostname versus assigned certificate SAN/wildcard coverage.</p>
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
                        No site TLS validation data
                      </td>
                    </tr>
                  ) : (
                    tlsSiteRows.map((row) => {
                      const certHosts = Array.isArray(row.presented_hosts) ? row.presented_hosts : [];
                      const detail = certHosts.length > 0 ? certHosts.join(', ') : row.reason;
                      const result = row.valid
                        ? 'match'
                        : row.status === 'mismatch'
                          ? 'mismatch'
                          : row.status;
                      const resultClass =
                        result === 'match'
                          ? styles.statusOk
                          : result === 'mismatch'
                            ? styles.statusMismatch
                            : result === 'pending'
                              ? styles.statusPending
                              : styles.statusUnknown;
                      return (
                        <tr key={row.host}>
                          <td className="mono">{row.host}</td>
                          <td>
                            <span className={`${styles.statusPill} ${resultClass}`}>{result}</span>
                          </td>
                          <td className="mono">{detail}</td>
                        </tr>
                      );
                    })
                  )}
                </tbody>
              </table>
            </div>
          </div>

        </>
      )}
    </section>
  );
}
