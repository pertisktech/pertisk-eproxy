import { useEffect, useState, useCallback } from 'react';
import { Link } from 'react-router-dom';
import {
  api,
  type HealthReport,
  type ProxyConfig,
  type ManagementInfo,
  type Metrics,
  type K8sPodRow,
} from '@/api/client';
import { formatBeamCpuPct, formatPertiskVmCpuLine, pertiskVmCpuTooltip } from '@/utils/beamCpu';
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

function formatTs(ms: number | null | undefined): string {
  if (ms == null || !Number.isFinite(ms)) return '—';
  try {
    return new Date(ms).toLocaleString();
  } catch {
    return String(ms);
  }
}

function upstreamForSite(config: ProxyConfig | null, host: string, backendName: string): string {
  const site = config?.sites?.find((s) => s.host === host);
  if (!site) return backendName;
  const backend = config?.backends?.find((b) => b.name === site.backend);
  return backend?.upstreams?.[0]?.addr ?? backendName;
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
  const caps = management?.runtime_capabilities;
  const listeners = Array.isArray(management?.listeners) ? management.listeners : [];
  const memBytes =
    management?.process_memory_bytes ??
    (typeof pi?.memory_total_bytes === 'number' ? pi.memory_total_bytes : null);
  const beamCpu = management?.process_cpu_usage_percent;

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
            <div className={styles.glanceMetrics} role="group" aria-label="Key proxy metrics">
              <div className={styles.metricTile}>
                <div className={styles.metricTileVal}>{config?.sites?.length ?? 0}</div>
                <div className={styles.metricTileLabel}>Sites</div>
              </div>
              <div className={styles.metricTile}>
                <div className={styles.metricTileVal}>{config?.backends?.length ?? 0}</div>
                <div className={styles.metricTileLabel}>Backends</div>
              </div>
              <div className={styles.metricTile}>
                <div className={styles.metricTileVal}>{(stats?.http_requests_total ?? 0).toLocaleString()}</div>
                <div className={styles.metricTileLabel}>Proxy requests (total)</div>
              </div>
              <div
                className={`${styles.metricTile} ${styles.metricTileHint}`}
                title="In-flight requests to backend upstreams (not admin UI sessions). Often 0 when idle."
              >
                <div className={styles.metricTileVal}>{stats?.active_connections ?? 0}</div>
                <div className={styles.metricTileLabel}>Upstream in flight</div>
              </div>
            </div>

            <div className={styles.glanceBottom}>
              <div className={`card ${styles.panel}`}>
                <h2 className={styles.panelTitle}>
                  <i className="fas fa-memory" aria-hidden /> VM resources
                </h2>
                <dl className={styles.kv}>
                  <dt>CPU</dt>
                  <dd title={pertiskVmCpuTooltip(pi?.logical_processors)}>
                    {beamCpu != null && Number.isFinite(beamCpu) ? (
                      <>
                        <div>{formatPertiskVmCpuLine(beamCpu, pi?.logical_processors)}</div>
                        <div className={styles.kvMuted}>Scheduler sample (internal): {formatBeamCpuPct(beamCpu)}</div>
                      </>
                    ) : (
                      '—'
                    )}
                  </dd>
                  <dt>Memory</dt>
                  <dd title="erlang:memory(total) — total allocated by the runtime.">
                    {memBytes != null ? `${formatBytes(memBytes)} allocated` : '—'}
                  </dd>
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

          <div className={`card ${styles.panel}`}>
            <h2 className={styles.panelTitle}>
              <i className="fas fa-network-wired" aria-hidden /> Public egress (dual-stack)
            </h2>
            <p className={styles.panelHint}>
              Outbound addresses as seen by ipify (refreshed periodically). Useful when this host is behind NAT or
              when validating IPv6 connectivity.
            </p>
            <div className={styles.ipRow}>
              <div className={styles.ipBox}>
                <span className={styles.ipLabel}>IPv4</span>
                <code className={styles.ipValue}>{management?.public_ipv4 ?? '—'}</code>
              </div>
              <div className={styles.ipBox}>
                <span className={styles.ipLabel}>IPv6</span>
                <code className={styles.ipValue}>{management?.public_ipv6 ?? '—'}</code>
              </div>
            </div>
            {management?.public_ip_error ? (
              <p className={styles.ipWarn}>
                <i className="fas fa-info-circle" aria-hidden /> {management.public_ip_error}
              </p>
            ) : null}
            <p className={styles.panelFoot}>Last fetch: {formatTs(management?.public_ip_fetched_at_ms ?? null)}</p>
          </div>

          <div className={`card ${styles.panel}`}>
            <h2 className={styles.panelTitle}>
              <i className="fas fa-plug" aria-hidden /> Listeners & ports
            </h2>
            <p className={styles.panelHint}>
              HTTP/HTTPS proxy uses separate Cowboy listeners on <strong>0.0.0.0</strong> and <strong>::</strong> (dual
              stack). Management API binds to the configured address only.
            </p>
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
            <dl className={styles.kvInline}>
              <dt>HTTP (display)</dt>
              <dd className="mono">{management?.http_addr ?? '—'}</dd>
              <dt>HTTPS</dt>
              <dd className="mono">{management?.https_addr?.trim() ? management.https_addr : '—'}</dd>
              <dt>Management</dt>
              <dd className="mono">{management?.management_addr ?? '—'}</dd>
              <dt
                title="ALPN on HTTPS (HTTP/1.1, HTTP/2). HTTP/3 is listed when the H3 API gateway or Cowboy QUIC UDP listener is enabled in config."
              >
                HTTP versions
              </dt>
              <dd>{(management?.http_versions ?? []).join(', ') || '—'}</dd>
            </dl>
          </div>

          <div className={`card ${styles.panel}`}>
            <h2 className={styles.panelTitle}>
              <i className="fas fa-check-double" aria-hidden /> Runtime capabilities
            </h2>
            <div className={styles.capGrid}>
              <div className={styles.capItem}>
                <span className={styles.capKey}>JIT</span>
                <span className={caps?.jit ? styles.capOn : styles.capOff}>{caps?.jit ? 'on' : 'off'}</span>
              </div>
              <div className={styles.capItem}>
                <span className={styles.capKey}>Cowboy QUIC API</span>
                <span className={caps?.cowboy_quic ? styles.capOn : styles.capOff}>
                  {caps?.cowboy_quic ? 'available' : 'unavailable'}
                </span>
              </div>
              <div className={styles.capItem}>
                <span className={styles.capKey}>quicer app</span>
                <span className={caps?.quicer_application ? styles.capOn : styles.capOff}>
                  {caps?.quicer_application ? 'loaded' : 'not loaded'}
                </span>
              </div>
              <div className={styles.capItem}>
                <span className={styles.capKey}>H3 API gateway (config)</span>
                <span className={caps?.h3_api_gateway_config ? styles.capOn : styles.capOff}>
                  {caps?.h3_api_gateway_config ? 'enabled' : 'disabled'}
                </span>
              </div>
              <div className={styles.capItem}>
                <span className={styles.capKey}>HTTPS listener</span>
                <span className={caps?.tls_listener_configured ? styles.capOn : styles.capOff}>
                  {caps?.tls_listener_configured ? 'configured' : 'not configured'}
                </span>
              </div>
              <div className={styles.capItem}>
                <span className={styles.capKey}>UDP HTTP/3 (Cowboy)</span>
                <span className={caps?.proxy_http3_udp ? styles.capOn : styles.capOff}>
                  {caps?.proxy_http3_udp ? 'enabled' : 'disabled'}
                </span>
              </div>
              <div className={styles.capItemWide}>
                <span className={styles.capKey}>BEAM target</span>
                <code className={styles.capCode}>{caps?.beam ?? '—'}</code>
              </div>
            </div>
          </div>

          {health?.backends && health.backends.length > 0 ? (
            <div className={`${styles.section} ${styles.healthSection}`}>
              <div className={styles.sectionTitle}>Backend health</div>
              <div className={`card ${styles.healthCard}`}>
                {health.backends.map((b) => (
                  <div key={b.name} className={styles.backendRow}>
                    <span className={styles.backendName}>{b.name}</span>
                    <span className={styles.backendStat}>
                      {b.healthy}/{b.total} healthy
                    </span>
                    <div className={styles.upBar} title={`${b.healthy} healthy of ${b.total}`}>
                      {Array.from({ length: Math.min(b.total, 24) }).map((_, i) => (
                        <span
                          key={i}
                          className={`${styles.upDot} ${i < b.healthy ? styles.upDotHealthy : styles.upDotUnhealthy}`}
                        />
                      ))}
                    </div>
                  </div>
                ))}
              </div>
            </div>
          ) : null}

          <div className={styles.section}>
            <div className={styles.sectionTitle}>Sites</div>
            <div className={`card ${styles.sitesCard}`}>
              {config?.sites?.length === 0 ? (
                <div className={styles.emptySites}>
                  No sites configured. <Link to="/sites">Add one →</Link>
                </div>
              ) : (
                <div className={styles.tableScroll}>
                  <table className={styles.table}>
                    <thead>
                      <tr>
                        <th>Host</th>
                        <th>Upstream</th>
                        <th>Routes</th>
                      </tr>
                    </thead>
                    <tbody>
                      {config?.sites.map((s) => (
                        <tr key={s.host}>
                          <td className="mono" style={{ color: 'var(--color-text)' }}>
                            {s.host}
                          </td>
                          <td>{upstreamForSite(config, s.host, s.backend)}</td>
                          <td>
                            <span className="badge badge-purple">{s.routes.length}</span>
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              )}
            </div>
          </div>
        </>
      )}
    </section>
  );
}
