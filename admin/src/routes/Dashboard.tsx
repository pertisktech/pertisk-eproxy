import { useEffect, useState, useCallback } from 'react';
import { Link } from 'react-router-dom';
import {
  api,
  type HealthReport,
  type ProxyConfig,
  type ManagementInfo,
  type Metrics,
} from '@/api/client';
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

function formatBeamCpuPct(n: number | undefined | null): string {
  if (n == null || !Number.isFinite(n)) return '—';
  return `${n.toFixed(1)}%`;
}

function formatUptime(secs: number | undefined): string {
  if (secs == null || !Number.isFinite(secs) || secs < 0) return '—';
  const d = Math.floor(secs / 86400);
  const h = Math.floor((secs % 86400) / 3600);
  const m = Math.floor((secs % 3600) / 60);
  const s = secs % 60;
  const parts: string[] = [];
  if (d) parts.push(`${d}d`);
  if (h || d) parts.push(`${h}h`);
  parts.push(`${m}m ${s}s`);
  return parts.join(' ');
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
          <p className={styles.heroSub}>
            pertisk_eproxy <span className="mono">{management?.version ?? '—'}</span>
            {management?.mode ? (
              <>
                {' '}
                · mode <span className="mono">{management.mode}</span>
              </>
            ) : null}
          </p>
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
          <span className={styles.heroPill} title="Wall-clock uptime since BEAM start">
            <i className="fas fa-clock" aria-hidden /> {formatUptime(stats?.uptime_secs)}
          </span>
          {beamCpu != null && Number.isFinite(beamCpu) ? (
            <span
              className={styles.heroPill}
              title="BEAM CPU: scheduler runtime ÷ wall time since the last sample. Can exceed 100% when using several cores."
            >
              <i className="fas fa-microchip" aria-hidden /> {formatBeamCpuPct(beamCpu)}
            </span>
          ) : null}
          {memBytes != null ? (
            <span className={styles.heroPill} title="BEAM total allocated memory (erlang:memory(total))">
              <i className="fas fa-memory" aria-hidden /> {formatBytes(memBytes)}
            </span>
          ) : null}
        </div>
      </div>

      {loading ? (
        <div className={styles.loadingWrap}>
          <div className="spinner" />
        </div>
      ) : (
        <>
          <div className={styles.grid}>
            <div className={`card ${styles.statCard}`}>
              <div className={`${styles.statIcon} ${styles.purple}`}>
                <i className="fas fa-globe" aria-hidden />
              </div>
              <div className={styles.statValue}>{config?.sites?.length ?? 0}</div>
              <div className={styles.statLabel}>Sites</div>
            </div>
            <div className={`card ${styles.statCard}`}>
              <div className={`${styles.statIcon} ${styles.blue}`}>
                <i className="fas fa-server" aria-hidden />
              </div>
              <div className={styles.statValue}>{config?.backends?.length ?? 0}</div>
              <div className={styles.statLabel}>Backends</div>
            </div>
            <div className={`card ${styles.statCard}`}>
              <div className={`${styles.statIcon} ${styles.yellow}`}>
                <i className="fas fa-exchange-alt" aria-hidden />
              </div>
              <div className={styles.statValue}>{stats?.http_requests_total ?? 0}</div>
              <div className={styles.statLabel}>HTTP requests (total)</div>
            </div>
            <div className={`card ${styles.statCard}`}>
              <div className={`${styles.statIcon} ${styles.green}`}>
                <i className="fas fa-link" aria-hidden />
              </div>
              <div className={styles.statValue}>{stats?.active_connections ?? 0}</div>
              <div className={styles.statLabel}>Upstream connections</div>
            </div>
            <div className={`card ${styles.statCard}`}>
              <div className={`${styles.statIcon} ${styles.orange}`}>
                <i className="fas fa-microchip" aria-hidden />
              </div>
              <div className={styles.statValue}>{formatBeamCpuPct(beamCpu ?? null)}</div>
              <div className={styles.statLabel}>BEAM CPU (recent)</div>
            </div>
            <div className={`card ${styles.statCard}`}>
              <div className={`${styles.statIcon} ${styles.teal}`}>
                <i className="fas fa-memory" aria-hidden />
              </div>
              <div className={styles.statValue}>{formatBytes(memBytes)}</div>
              <div className={styles.statLabel}>BEAM memory</div>
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
                <dt>CPU (BEAM)</dt>
                <dd title="Scheduler runtime ÷ wall time since last sample; can exceed 100% on multi-core.">
                  {formatBeamCpuPct(beamCpu ?? null)}
                </dd>
                <dt>Memory (allocated)</dt>
                <dd title="erlang:memory(total) — total allocated by the runtime.">{formatBytes(memBytes)}</dd>
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
            <div className="card" style={{ padding: 0 }}>
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
