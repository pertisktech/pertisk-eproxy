import { useEffect, useState } from 'react';
import { api } from '@/api/client';
import styles from './Settings.module.css';

type ConfigMap = Record<string, unknown>;

function asRecord(value: unknown): ConfigMap | null {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null;
  return value as ConfigMap;
}

function formatValue(value: unknown): string {
  if (value === null || value === undefined) return '-';
  if (typeof value === 'boolean') return value ? 'true' : 'false';
  if (typeof value === 'number' || typeof value === 'bigint') return String(value);
  if (typeof value === 'string') return value.length > 0 ? value : '-';
  if (Array.isArray(value)) return `${value.length} item(s)`;
  if (typeof value === 'object') return 'Object';
  return String(value);
}

function renderKeyValueTable(cfg: ConfigMap, keys: string[]) {
  const rows = keys.filter((k) => cfg[k] !== undefined).map((k) => ({ key: k, value: cfg[k] }));
  if (rows.length === 0) {
    return <div className={styles.emptyText}>No fields in this section.</div>;
  }
  return (
    <table className={styles.kvTable}>
      <thead>
        <tr>
          <th>Field</th>
          <th>Value</th>
        </tr>
      </thead>
      <tbody>
        {rows.map((row) => (
          <tr key={row.key}>
            <td>{row.key}</td>
            <td>{formatValue(row.value)}</td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}

function renderSites(cfg: ConfigMap) {
  const sites = Array.isArray(cfg.sites) ? cfg.sites : [];
  if (sites.length === 0) return <div className={styles.emptyText}>No sites.</div>;
  return (
    <div className={styles.listGrid}>
      {sites.map((entry, idx) => {
        const site = asRecord(entry);
        const host = formatValue(site?.host);
        const backend = formatValue(site?.backend);
        const cert = formatValue(site?.certificate);
        const routes = Array.isArray(site?.routes) ? site?.routes.length : 0;
        return (
          <div key={`${host}-${idx}`} className={styles.itemCard}>
            <div className={styles.itemTitle}>{host}</div>
            <div className={styles.itemMeta}>backend: {backend}</div>
            <div className={styles.itemMeta}>certificate: {cert}</div>
            <div className={styles.itemMeta}>routes: {routes}</div>
          </div>
        );
      })}
    </div>
  );
}

function renderBackends(cfg: ConfigMap) {
  const backends = Array.isArray(cfg.backends) ? cfg.backends : [];
  if (backends.length === 0) return <div className={styles.emptyText}>No backends.</div>;
  return (
    <div className={styles.listGrid}>
      {backends.map((entry, idx) => {
        const backend = asRecord(entry);
        const name = formatValue(backend?.name);
        const algorithm = formatValue(backend?.algorithm);
        const upstreams = Array.isArray(backend?.upstreams) ? backend?.upstreams.length : 0;
        return (
          <div key={`${name}-${idx}`} className={styles.itemCard}>
            <div className={styles.itemTitle}>{name}</div>
            <div className={styles.itemMeta}>algorithm: {algorithm}</div>
            <div className={styles.itemMeta}>upstreams: {upstreams}</div>
          </div>
        );
      })}
    </div>
  );
}

function renderDnsProviders(cfg: ConfigMap) {
  const providers = Array.isArray(cfg.dns_providers) ? cfg.dns_providers : [];
  if (providers.length === 0) return <div className={styles.emptyText}>No DNS providers.</div>;
  return (
    <div className={styles.listGrid}>
      {providers.map((entry, idx) => {
        if (typeof entry === 'string') {
          return (
            <div key={`${entry}-${idx}`} className={styles.itemCard}>
              <div className={styles.itemTitle}>{entry}</div>
              <div className={styles.itemMeta}>type: legacy</div>
            </div>
          );
        }
        const provider = asRecord(entry);
        const name = formatValue(provider?.name);
        const ptype = formatValue(provider?.provider_type);
        return (
          <div key={`${name}-${idx}`} className={styles.itemCard}>
            <div className={styles.itemTitle}>{name}</div>
            <div className={styles.itemMeta}>type: {ptype}</div>
          </div>
        );
      })}
    </div>
  );
}

export default function Settings() {
  const [reloading, setReloading] = useState(false);
  const [loadingConfig, setLoadingConfig] = useState(false);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [configData, setConfigData] = useState<ConfigMap | null>(null);
  const [configEndpoint, setConfigEndpoint] = useState('/api/config?show_all=1');

  const loadConfig = async (silent = false) => {
    if (!silent) {
      setLoadingConfig(true);
      setMsg(null);
    }
    try {
      setConfigEndpoint('/api/config?show_all=1');
      const cfg = await api.configAll();
      setConfigData(asRecord(cfg));
      if (!silent) {
        setMsg({ ok: true, text: 'Config loaded successfully.' });
      }
    } catch (e: unknown) {
      if (!silent) {
        setMsg({ ok: false, text: String(e) });
      }
    } finally {
      if (!silent) {
        setLoadingConfig(false);
      }
    }
  };

  useEffect(() => {
    void loadConfig(false);
  }, []);

  const reload = async () => {
    setReloading(true);
    setMsg(null);
    try {
      await api.reload();
      setMsg({ ok: true, text: 'Config reloaded successfully.' });
    } catch (e: unknown) {
      setMsg({ ok: false, text: String(e) });
    } finally {
      setReloading(false);
    }
  };

  return (
    <div className={styles.page}>
      {msg && (
        <div className={msg.ok ? 'success-banner' : 'error-banner'}>
          <i className={`fas ${msg.ok ? 'fa-check-circle' : 'fa-exclamation-circle'}`} />
          {msg.text}
        </div>
      )}

      <div className="card">
        <h2 style={{ marginBottom: 12 }}>Hot Reload</h2>
        <button className="btn btn-primary" type="button" onClick={() => void reload()} disabled={reloading}>
          {reloading ? (
            <>
              <span className="spinner" style={{ width: 14, height: 14 }} /> Reloading…
            </>
          ) : (
            <>
              <i className="fas fa-sync-alt" /> Reload Config
            </>
          )}
        </button>
      </div>

      <div className="card">
        <h2 style={{ marginBottom: 12 }}>Config View</h2>
        <p className={styles.helpText}>Structured full config for both proxy and ingress modes.</p>
        <div className={styles.endpointLine}>Loading from {configEndpoint}</div>
        <div className={styles.actionsRow}>
          <button className="btn btn-primary" type="button" onClick={() => void loadConfig()} disabled={loadingConfig}>
            {loadingConfig ? (
              <>
                <span className="spinner" style={{ width: 14, height: 14 }} /> Loading…
              </>
            ) : (
              <>
                <i className="fas fa-table" /> Refresh Config View
              </>
            )}
          </button>
        </div>

        {!configData ? (
          <div className={styles.emptyText}>No config loaded yet.</div>
        ) : (
          <div className={styles.sectionsWrap}>
            <section>
              <h3 className={styles.sectionTitle}>General</h3>
              {renderKeyValueTable(configData, ['mode', 'log_level'])}
            </section>

            <section>
              <h3 className={styles.sectionTitle}>Listeners</h3>
              {renderKeyValueTable(configData, [
                'http_addr',
                'http_port',
                'https_port',
                'management_addr',
                'management_port',
                'metrics_addr',
                'metrics_port',
                'metrics_enabled',
              ])}
            </section>

            <section>
              <h3 className={styles.sectionTitle}>Logging</h3>
              {renderKeyValueTable(configData, ['proxy_access_log', 'health_access_log', 'health_cache_refresh_ms'])}
            </section>

            <section>
              <h3 className={styles.sectionTitle}>HTTP/3 / QUIC</h3>
              {renderKeyValueTable(configData, [
                'quic_enabled',
                'quic_port',
                'h3_udp_bind',
                'h3_quic_pool_size',
                'h3_max_streams',
                'h3_stream_receive_window',
                'h3_conn_receive_window',
                'h3_idle_timeout_secs',
                'h3_keepalive_interval_secs',
              ])}
            </section>

            <section>
              <h3 className={styles.sectionTitle}>Sites</h3>
              {renderSites(configData)}
            </section>

            <section>
              <h3 className={styles.sectionTitle}>Backends</h3>
              {renderBackends(configData)}
            </section>

            <section>
              <h3 className={styles.sectionTitle}>DNS Providers</h3>
              {renderDnsProviders(configData)}
            </section>
          </div>
        )}
      </div>
    </div>
  );
}
