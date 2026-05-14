import { useEffect, useState, useCallback } from 'react';
import { Link } from 'react-router-dom';
import {
  api,
  type HealthReport,
  type ProxyConfig,
  type ManagementInfo,
  type Metrics,
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
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(() => dashboardCache == null);

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
                <dt>Database</dt>
                <dd className="mono">{management?.db_path ?? '—'}</dd>
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
                title="ALPN on HTTPS (HTTP/1.1, HTTP/2). HTTP/3 is listed when the erlang_quic H3 API gateway is enabled."
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
                <span className={styles.capKey}>UDP HTTP/3 (erlang_quic)</span>
                <span className={caps?.proxy_http3_udp ? styles.capOn : styles.capOff}>
                  {caps?.proxy_http3_udp ? 'enabled' : 'disabled'}
                </span>
              </div>
              <div className={styles.capItem}>
                <span className={styles.capKey}>QUIC IPv4-only bind</span>
                <span className={caps?.h3_quic_ipv4_only ? styles.capOn : styles.capOff}>
                  {caps?.h3_quic_ipv4_only ? 'yes' : 'no'}
                </span>
              </div>
              <div className={styles.capItemWide}>
                <span className={styles.capKey}>BEAM target</span>
                <code className={styles.capCode}>{caps?.beam ?? '—'}</code>
              </div>
            </div>
            {caps?.http3_chrome_ipv6_hint ? (
              <p className={styles.http3Hint} role="note">
                {caps.http3_chrome_ipv6_hint}
              </p>
            ) : null}
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
