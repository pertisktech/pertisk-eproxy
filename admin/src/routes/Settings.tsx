import { useEffect, useMemo, useState, type ReactNode } from 'react';
import { Link } from 'react-router-dom';
import { api } from '@/api/client';
import FaIcon from '@/components/FaIcon';
import { useMode } from '@/context/ModeContext';
import { useToast } from '@/context/ToastContext';
import styles from './Settings.module.css';

type ConfigMap = Record<string, unknown>;
type ModeInfo = {
  runtimeMode?: string;
  deploymentMode?: string;
  supportedMode?: string;
};

type SectionId = 'mode' | 'general' | 'listeners' | 'logging' | 'http3' | 'sites' | 'backends' | 'dns';

type FieldRow = {
  key: string;
  label: string;
  value: unknown;
};

const SECTION_ORDER: SectionId[] = ['mode', 'general', 'listeners', 'logging', 'http3', 'sites', 'backends', 'dns'];

const SECTION_META: Record<
  SectionId,
  { title: string; icon: string; badge?: (cfg: ConfigMap, mode: ModeInfo) => string | null }
> = {
  mode: {
    title: 'Deployment mode',
    icon: 'fa-layer-group',
    badge: (_cfg, mode) => mode.runtimeMode ?? mode.deploymentMode ?? null,
  },
  general: {
    title: 'General',
    icon: 'fa-sliders',
  },
  listeners: {
    title: 'Listeners',
    icon: 'fa-network-wired',
  },
  logging: {
    title: 'Logging',
    icon: 'fa-file-lines',
  },
  http3: {
    title: 'HTTP/3 / QUIC',
    icon: 'fa-bolt',
    badge: (cfg) => {
      const gw = cfg.h3_api_gateway_enabled;
      const quic = cfg.quic_enabled;
      if (gw === false || quic === false) return 'partial';
      if (gw === true && quic === true) return 'enabled';
      return null;
    },
  },
  sites: {
    title: 'Sites',
    icon: 'fa-globe',
    badge: (cfg) => {
      const n = Array.isArray(cfg.sites) ? cfg.sites.length : 0;
      return n > 0 ? String(n) : null;
    },
  },
  backends: {
    title: 'Backends',
    icon: 'fa-server',
    badge: (cfg) => {
      const n = Array.isArray(cfg.backends) ? cfg.backends.length : 0;
      return n > 0 ? String(n) : null;
    },
  },
  dns: {
    title: 'DNS providers',
    icon: 'fa-cloud',
    badge: (cfg) => {
      const n = Array.isArray(cfg.dns_providers) ? cfg.dns_providers.length : 0;
      return n > 0 ? String(n) : null;
    },
  },
};

const FIELD_LABELS: Record<string, string> = {
  mode: 'Runtime mode',
  log_level: 'Log level',
  http_addr: 'HTTP bind address',
  http_port: 'HTTP port',
  https_port: 'HTTPS port',
  management_addr: 'Management bind address',
  management_port: 'Management port',
  metrics_addr: 'Metrics bind address',
  metrics_port: 'Metrics port',
  metrics_enabled: 'Metrics enabled',
  proxy_access_log: 'Proxy access log',
  health_access_log: 'Health access log',
  health_cache_refresh_ms: 'Health cache refresh (ms)',
  h3_api_gateway_enabled: 'H3 API gateway',
  quic_enabled: 'QUIC listener',
  quic_port: 'QUIC port',
  h3_udp_bind: 'UDP bind address',
  h3_quic_pool_size: 'QUIC pool size',
  h3_congestion_control: 'Congestion control',
  h3_max_streams: 'Max streams',
  h3_stream_receive_window: 'Stream receive window',
  h3_conn_receive_window: 'Connection receive window',
  h3_idle_timeout_secs: 'Idle timeout (s)',
  h3_keepalive_interval_secs: 'Keepalive interval (s)',
};

function asRecord(value: unknown): ConfigMap | null {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null;
  return value as ConfigMap;
}

function labelForKey(key: string): string {
  return FIELD_LABELS[key] ?? key.replace(/_/g, ' ');
}

function formatScalar(value: unknown): string {
  if (value === null || value === undefined) return '—';
  if (typeof value === 'boolean') return value ? 'true' : 'false';
  if (typeof value === 'number' || typeof value === 'bigint') return String(value);
  if (typeof value === 'string') return value.length > 0 ? value : '—';
  if (Array.isArray(value)) return `${value.length} item(s)`;
  if (typeof value === 'object') return 'Object';
  return String(value);
}

function listenEndpoint(addrKey: string, portKey: string, cfg: ConfigMap, defaultAddr = '0.0.0.0'): string {
  const addr = typeof cfg[addrKey] === 'string' && cfg[addrKey] ? String(cfg[addrKey]) : defaultAddr;
  const port = cfg[portKey];
  if (port === null || port === undefined || port === '') return addr;
  return `${addr}:${port}`;
}

function BoolPill({ value }: { value: boolean }) {
  return (
    <span className={`${styles.boolPill} ${value ? styles.boolOn : styles.boolOff}`}>
      <FaIcon className={`fas ${value ? 'fa-circle-check' : 'fa-circle'}`} aria-hidden />
      {value ? 'On' : 'Off'}
    </span>
  );
}

function renderConfigValue(value: unknown): ReactNode {
  if (typeof value === 'boolean') return <BoolPill value={value} />;
  if (value === null || value === undefined) return <span className={styles.kvValue}>—</span>;
  if (typeof value === 'number' || typeof value === 'bigint') {
    return <span className={`${styles.kvValue} ${styles.kvMono}`}>{String(value)}</span>;
  }
  if (typeof value === 'string') {
    return <span className={styles.kvValue}>{value.length > 0 ? value : '—'}</span>;
  }
  return <span className={styles.kvValue}>{formatScalar(value)}</span>;
}

function KeyValueGrid({ rows }: { rows: FieldRow[] }) {
  if (rows.length === 0) {
    return <p className={styles.emptyText}>No fields in this section.</p>;
  }
  return (
    <div className={styles.kvGrid}>
      {rows.map((row) => (
        <div key={row.key} className={styles.kvRow}>
          <div className={styles.kvKey}>{row.label}</div>
          <div>{renderConfigValue(row.value)}</div>
        </div>
      ))}
    </div>
  );
}

function buildFieldRows(cfg: ConfigMap, keys: string[]): FieldRow[] {
  return keys
    .filter((k) => cfg[k] !== undefined)
    .map((k) => ({ key: k, label: labelForKey(k), value: cfg[k] }));
}

function listenerRows(cfg: ConfigMap): FieldRow[] {
  const rows: FieldRow[] = [];
  if (cfg.http_port !== undefined || cfg.http_addr !== undefined) {
    rows.push({ key: 'http_listen', label: 'HTTP', value: listenEndpoint('http_addr', 'http_port', cfg) });
  }
  if (cfg.https_port !== undefined) {
    rows.push({
      key: 'https_listen',
      label: 'HTTPS',
      value: listenEndpoint('http_addr', 'https_port', cfg),
    });
  }
  if (cfg.management_port !== undefined || cfg.management_addr !== undefined) {
    rows.push({
      key: 'management_listen',
      label: 'Management API',
      value: listenEndpoint('management_addr', 'management_port', cfg, '127.0.0.1'),
    });
  }
  if (cfg.metrics_port !== undefined || cfg.metrics_addr !== undefined || cfg.metrics_enabled !== undefined) {
    rows.push({
      key: 'metrics_enabled',
      label: 'Metrics',
      value:
        cfg.metrics_enabled === false
          ? false
          : listenEndpoint('metrics_addr', 'metrics_port', cfg, '127.0.0.1'),
    });
  }
  return rows;
}

function renderSites(cfg: ConfigMap) {
  const sites = Array.isArray(cfg.sites) ? cfg.sites : [];
  const backends = Array.isArray(cfg.backends) ? cfg.backends : [];
  if (sites.length === 0) return <p className={styles.emptyText}>No sites configured.</p>;

  return (
    <div className={styles.listGrid}>
      {sites.map((entry, idx) => {
        const site = asRecord(entry);
        const host = formatScalar(site?.host);
        const backendName = typeof site?.backend === 'string' ? site.backend : '—';
        const backend = backends.map(asRecord).find((b) => b?.name === backendName);
        const grpc = backend?.grpc_upstream === true;
        const h3 = !grpc && site?.advertise_http3 !== false;
        const cert = formatScalar(site?.certificate);
        const routes = Array.isArray(site?.routes) ? site.routes.length : 0;
        const wildcard = typeof site?.host === 'string' && site.host.startsWith('*.');
        return (
          <div key={`${host}-${idx}`} className={styles.itemCard}>
            <div className={styles.itemTitle}>{host}</div>
            <div className={styles.chipRow} style={{ marginBottom: '0.45rem' }}>
              {wildcard ? <span className={styles.chip}>Wildcard</span> : null}
              {grpc ? <span className={`${styles.chip} ${styles.chipAccent}`}>gRPC upstream</span> : null}
              <span className={h3 ? styles.chip : `${styles.chip} ${styles.chipMuted}`}>
                {h3 ? 'H3 Alt-Svc on' : 'H3 Alt-Svc off'}
              </span>
            </div>
            <div className={styles.itemMetaGrid}>
              <div className={styles.itemMetaRow}>
                <span className={styles.itemMetaLabel}>Backend</span>
                <span className={styles.itemMetaValue}>{backendName}</span>
              </div>
              <div className={styles.itemMetaRow}>
                <span className={styles.itemMetaLabel}>Certificate</span>
                <span className={styles.itemMetaValue}>{cert}</span>
              </div>
              <div className={styles.itemMetaRow}>
                <span className={styles.itemMetaLabel}>Routes</span>
                <span className={styles.itemMetaValue}>{routes}</span>
              </div>
            </div>
          </div>
        );
      })}
    </div>
  );
}

function renderBackends(cfg: ConfigMap) {
  const backends = Array.isArray(cfg.backends) ? cfg.backends : [];
  if (backends.length === 0) return <p className={styles.emptyText}>No backends configured.</p>;

  return (
    <div className={styles.listGrid}>
      {backends.map((entry, idx) => {
        const backend = asRecord(entry);
        const name = formatScalar(backend?.name);
        const algorithm = formatScalar(backend?.algorithm);
        const upstreamList = Array.isArray(backend?.upstreams) ? backend.upstreams : [];
        const firstUpstream = asRecord(upstreamList[0]);
        const firstAddr = firstUpstream?.addr != null ? String(firstUpstream.addr) : null;
        const grpc = backend?.grpc_upstream === true;
        return (
          <div key={`${name}-${idx}`} className={styles.itemCard}>
            <div className={styles.itemTitle}>{name}</div>
            <div className={styles.chipRow} style={{ marginBottom: '0.45rem' }}>
              <span className={styles.chip}>{algorithm}</span>
              {grpc ? <span className={`${styles.chip} ${styles.chipAccent}`}>gRPC</span> : null}
              <span className={styles.chipMuted}>{upstreamList.length} upstream(s)</span>
            </div>
            {firstAddr ? (
              <div className={styles.itemMetaRow}>
                <span className={styles.itemMetaLabel}>Primary</span>
                <span className={`${styles.itemMetaValue} ${styles.kvMono}`}>{firstAddr}</span>
              </div>
            ) : null}
          </div>
        );
      })}
    </div>
  );
}

function renderDnsProviders(cfg: ConfigMap) {
  const providers = Array.isArray(cfg.dns_providers) ? cfg.dns_providers : [];
  if (providers.length === 0) return <p className={styles.emptyText}>No DNS providers configured.</p>;

  return (
    <div className={styles.listGrid}>
      {providers.map((entry, idx) => {
        if (typeof entry === 'string') {
          return (
            <div key={`${entry}-${idx}`} className={styles.itemCard}>
              <div className={styles.itemTitle}>{entry}</div>
              <span className={`${styles.chip} ${styles.chipMuted}`}>Legacy reference</span>
            </div>
          );
        }
        const provider = asRecord(entry);
        const name = formatScalar(provider?.name);
        const ptype = formatScalar(provider?.provider_type);
        return (
          <div key={`${name}-${idx}`} className={styles.itemCard}>
            <div className={styles.itemTitle}>{name}</div>
            <span className={styles.chip}>{ptype}</span>
          </div>
        );
      })}
    </div>
  );
}

function ConfigSection({
  id,
  title,
  icon,
  badge,
  expanded,
  onToggle,
  children,
}: {
  id: SectionId;
  title: string;
  icon: string;
  badge?: string | null;
  expanded: boolean;
  onToggle: (id: SectionId) => void;
  children: ReactNode;
}) {
  const panelId = `settings-section-${id}`;
  return (
    <section className={styles.sectionCard}>
      <button
        type="button"
        className={styles.sectionHeader}
        aria-expanded={expanded}
        aria-controls={panelId}
        onClick={() => onToggle(id)}
      >
        <span className={styles.sectionIcon}>
          <FaIcon className={`fas ${icon}`} aria-hidden />
        </span>
        <span className={styles.sectionTitleText}>{title}</span>
        {badge ? <span className={styles.sectionBadge}>{badge}</span> : null}
        <FaIcon
          className={`fas fa-chevron-down ${styles.sectionChevron} ${expanded ? styles.sectionChevronOpen : ''}`}
          aria-hidden
        />
      </button>
      {expanded ? (
        <div id={panelId} className={styles.sectionBody}>
          {children}
        </div>
      ) : null}
    </section>
  );
}

export default function Settings() {
  const contextMode = useMode();
  const toast = useToast();
  const [reloading, setReloading] = useState(false);
  const [loadingConfig, setLoadingConfig] = useState(true);
  const [configData, setConfigData] = useState<ConfigMap | null>(null);
  const [modeInfo, setModeInfo] = useState<ModeInfo>({});
  const [expanded, setExpanded] = useState<Set<SectionId>>(
    () => new Set<SectionId>(['mode', 'general', 'listeners', 'http3', 'sites', 'backends']),
  );

  const loadConfig = async (opts?: { silent?: boolean }) => {
    const silent = opts?.silent === true;
    if (!silent) setLoadingConfig(true);
    try {
      let cfg: unknown;
      try {
        cfg = await api.configAll();
      } catch {
        cfg = await api.config();
      }
      const cfgMap = asRecord(cfg);
      setConfigData(cfgMap);
      const runtimeMode =
        typeof cfgMap?.mode === 'string'
          ? cfgMap.mode
          : contextMode === 'proxy' || contextMode === 'ingress'
            ? contextMode
            : undefined;
      setModeInfo((prev) => ({
        ...prev,
        runtimeMode: runtimeMode ?? prev.runtimeMode,
      }));
      if (!silent) toast.success('Configuration refreshed.');
    } catch (e: unknown) {
      toast.error(e instanceof Error ? e.message : String(e));
    } finally {
      if (!silent) setLoadingConfig(false);
    }
  };

  useEffect(() => {
    void loadConfig({ silent: true }).finally(() => setLoadingConfig(false));
    void api
      .authConfig()
      .then((authCfg) => {
        setModeInfo((prev) => ({
          ...prev,
          deploymentMode:
            authCfg.deployment_mode === 'proxy' || authCfg.deployment_mode === 'ingress'
              ? authCfg.deployment_mode
              : prev.deploymentMode,
          supportedMode: authCfg.mode,
          runtimeMode:
            prev.runtimeMode ??
            (authCfg.deployment_mode === 'proxy' || authCfg.deployment_mode === 'ingress'
              ? authCfg.deployment_mode
              : undefined),
        }));
      })
      .catch(() => undefined);
    // eslint-disable-next-line react-hooks/exhaustive-deps -- initial load only
  }, []);

  const summary = useMemo(() => {
    const sites = Array.isArray(configData?.sites) ? configData.sites.length : 0;
    const backends = Array.isArray(configData?.backends) ? configData.backends.length : 0;
    const h3Gw = configData?.h3_api_gateway_enabled;
    const quic = configData?.quic_enabled;
    let h3Label = '—';
    if (h3Gw === false || quic === false) h3Label = 'Partial';
    else if (h3Gw === true && quic === true) h3Label = 'Enabled';
    else if (h3Gw === false && quic === false) h3Label = 'Disabled';

    return {
      mode: modeInfo.runtimeMode ?? modeInfo.deploymentMode ?? contextMode ?? '—',
      sites,
      backends,
      h3Label,
      quicPort: configData?.quic_port != null ? String(configData.quic_port) : null,
    };
  }, [configData, contextMode, modeInfo.deploymentMode, modeInfo.runtimeMode]);

  const toggleSection = (id: SectionId) => {
    setExpanded((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  };

  const expandAll = () => setExpanded(new Set(SECTION_ORDER));
  const collapseAll = () => setExpanded(new Set());

  const copyRawJson = async () => {
    if (!configData) return;
    try {
      await navigator.clipboard.writeText(JSON.stringify(configData, null, 2));
      toast.success('Raw config copied to clipboard.');
    } catch {
      toast.error('Could not copy config to clipboard.');
    }
  };

  const reload = async () => {
    setReloading(true);
    try {
      await api.reload();
      toast.success('Configuration reloaded on the server.');
      await loadConfig({ silent: true });
    } catch (e: unknown) {
      toast.error(e instanceof Error ? e.message : String(e));
    } finally {
      setReloading(false);
    }
  };

  const renderSectionBody = (id: SectionId): ReactNode => {
    if (!configData && id !== 'mode') {
      return <p className={styles.emptyText}>No config loaded yet.</p>;
    }

    switch (id) {
      case 'mode':
        return (
          <KeyValueGrid
            rows={[
              {
                key: 'runtime_mode',
                label: 'Runtime mode',
                value: modeInfo.runtimeMode ?? contextMode ?? null,
              },
              {
                key: 'deployment_mode',
                label: 'Deployment mode',
                value: modeInfo.deploymentMode ?? contextMode ?? null,
              },
              { key: 'supported_mode', label: 'Supported mode', value: modeInfo.supportedMode ?? null },
            ]}
          />
        );
      case 'general':
        return <KeyValueGrid rows={buildFieldRows(configData!, ['mode', 'log_level'])} />;
      case 'listeners':
        return <KeyValueGrid rows={listenerRows(configData!)} />;
      case 'logging':
        return (
          <KeyValueGrid
            rows={buildFieldRows(configData!, ['proxy_access_log', 'health_access_log', 'health_cache_refresh_ms'])}
          />
        );
      case 'http3':
        return (
          <KeyValueGrid
            rows={buildFieldRows(configData!, [
              'h3_api_gateway_enabled',
              'quic_enabled',
              'quic_port',
              'h3_udp_bind',
              'h3_quic_pool_size',
              'h3_congestion_control',
              'h3_max_streams',
              'h3_stream_receive_window',
              'h3_conn_receive_window',
              'h3_idle_timeout_secs',
              'h3_keepalive_interval_secs',
            ])}
          />
        );
      case 'sites':
        return (
          <>
            {renderSites(configData!)}
            <p className={styles.emptyText} style={{ marginTop: '0.65rem' }}>
              <Link to="/sites">Manage sites</Link> to edit hosts, HTTP/3, and gRPC settings.
            </p>
          </>
        );
      case 'backends':
        return renderBackends(configData!);
      case 'dns':
        return (
          <>
            {renderDnsProviders(configData!)}
            <p className={styles.emptyText} style={{ marginTop: '0.65rem' }}>
              <Link to="/dns-providers">Manage DNS providers</Link> for ACME DNS-01.
            </p>
          </>
        );
      default:
        return null;
    }
  };

  return (
    <div className={styles.page}>
      <div className="card">
        <div className={styles.configHero}>
          <div className={styles.configHeroCopy}>
            <p className={styles.configEyebrow}>Settings</p>
            <h2 className={styles.configTitle}>Configuration overview</h2>
            <p className={styles.configSubtitle}>
              Read-only snapshot of the running proxy config. Use Sites and DNS pages to make changes, then hot
              reload below.
            </p>
          </div>
          <div className={styles.configActions}>
            <button
              type="button"
              className={styles.btnGhost}
              onClick={() => void copyRawJson()}
              disabled={!configData}
            >
              <FaIcon className="fas fa-copy" aria-hidden /> Copy JSON
            </button>
            <button
              type="button"
              className={styles.btnPrimary}
              onClick={() => void loadConfig()}
              disabled={loadingConfig}
            >
              {loadingConfig ? (
                <>
                  <FaIcon className="fas fa-spinner fa-spin" aria-hidden /> Loading…
                </>
              ) : (
                <>
                  <FaIcon className="fas fa-rotate" aria-hidden /> Refresh
                </>
              )}
            </button>
          </div>
        </div>

        <div className={styles.summaryGrid}>
          <div className={styles.summaryTile}>
            <span className={styles.summaryLabel}>Mode</span>
            <span className={styles.summaryValue}>{summary.mode}</span>
            {modeInfo.deploymentMode && modeInfo.deploymentMode !== summary.mode ? (
              <span className={styles.summarySub}>deploy: {modeInfo.deploymentMode}</span>
            ) : null}
          </div>
          <div className={styles.summaryTile}>
            <span className={styles.summaryLabel}>Sites</span>
            <span className={styles.summaryValue}>{summary.sites}</span>
            <span className={styles.summarySub}>reverse proxy hosts</span>
          </div>
          <div className={styles.summaryTile}>
            <span className={styles.summaryLabel}>Backends</span>
            <span className={styles.summaryValue}>{summary.backends}</span>
            <span className={styles.summarySub}>upstream pools</span>
          </div>
          <div className={styles.summaryTile}>
            <span className={styles.summaryLabel}>HTTP/3</span>
            <span className={styles.summaryValue}>{summary.h3Label}</span>
            {summary.quicPort ? <span className={styles.summarySub}>UDP :{summary.quicPort}</span> : null}
          </div>
        </div>

        <div className={styles.sectionsToolbar}>
          <p className={styles.sectionsHint}>Expand a section for details.</p>
          <div className={styles.configActions}>
            <button type="button" className={styles.btnGhost} onClick={expandAll}>
              Expand all
            </button>
            <button type="button" className={styles.btnGhost} onClick={collapseAll}>
              Collapse all
            </button>
          </div>
        </div>

        <div className={styles.sectionsWrap}>
          {SECTION_ORDER.map((id) => {
            const meta = SECTION_META[id];
            const badge = meta.badge?.(configData ?? {}, modeInfo) ?? null;
            return (
              <ConfigSection
                key={id}
                id={id}
                title={meta.title}
                icon={meta.icon}
                badge={badge}
                expanded={expanded.has(id)}
                onToggle={toggleSection}
              >
                {renderSectionBody(id)}
              </ConfigSection>
            );
          })}
        </div>
      </div>

      <div className="card">
        <div className={styles.reloadCard}>
          <div className={styles.reloadCopy}>
            <h2 className={styles.reloadTitle}>Hot reload</h2>
            <p className={styles.reloadText}>
              Apply configuration changes from disk or the database without restarting the Erlang VM.
            </p>
          </div>
          <button type="button" className={styles.btnPrimary} onClick={() => void reload()} disabled={reloading}>
            {reloading ? (
              <>
                <FaIcon className="fas fa-spinner fa-spin" aria-hidden /> Reloading…
              </>
            ) : (
              <>
                <FaIcon className="fas fa-sync-alt" aria-hidden /> Reload config
              </>
            )}
          </button>
        </div>
      </div>
    </div>
  );
}
