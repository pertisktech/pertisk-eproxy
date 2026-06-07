import { useState } from 'react';
import type { ManagementInfo } from '@/api/client';
import styles from './PrometheusScrapePanel.module.css';

const PROMETHEUS_SERIES = [
  'pertisk_eproxy_requests_total',
  'pertisk_eproxy_site_requests_total',
  'pertisk_eproxy_bytes_sent_total',
  'pertisk_eproxy_bytes_received_total',
  'pertisk_eproxy_request_duration_ms',
  'pertisk_eproxy_upstream_connections',
  'pertisk_eproxy_upstream_healthy',
] as const;

export function resolveMetricsEndpoints(mgmt: ManagementInfo | null | undefined): {
  enabled: boolean;
  metricsUrl: string;
  healthUrl: string;
  legacyUrl: string;
} {
  const enabled = mgmt?.metrics_enabled !== false;
  const legacyBase =
    typeof window !== 'undefined' ? window.location.origin : 'http://localhost:9080';
  const legacyUrl = `${legacyBase}/api/metrics`;

  if (mgmt?.metrics_addr) {
    const raw = mgmt.metrics_addr.trim();
    const base = raw.startsWith('http://') || raw.startsWith('https://') ? raw.replace(/\/$/, '') : `http://${raw}`;
    return {
      enabled,
      metricsUrl: `${base}/metrics`,
      healthUrl: `${base}/health`,
      legacyUrl,
    };
  }

  const metricsListener = mgmt?.listeners?.find((l) => l.id === 'metrics');
  const host =
    mgmt?.process_info?.hostname ??
    (typeof window !== 'undefined' ? window.location.hostname : 'localhost');
  const port = metricsListener?.port ?? 9090;
  const base = `http://${host}:${port}`;
  return {
    enabled,
    metricsUrl: `${base}/metrics`,
    healthUrl: `${base}/health`,
    legacyUrl,
  };
}

type PrometheusScrapePanelProps = {
  management: ManagementInfo | null | undefined;
  compact?: boolean;
};

export default function PrometheusScrapePanel({ management, compact = false }: PrometheusScrapePanelProps) {
  const [copied, setCopied] = useState<string | null>(null);
  const { enabled, metricsUrl, healthUrl, legacyUrl } = resolveMetricsEndpoints(management);

  function copyUrl(url: string, key: string) {
    void navigator.clipboard.writeText(url).then(
      () => {
        setCopied(key);
        setTimeout(() => setCopied(null), 2000);
      },
      () => {},
    );
  }

  return (
    <section className={`${styles.section} ${compact ? styles.compact : ''}`}>
      <div className={styles.header}>
        <h2 className={styles.title}>
          <i className="fas fa-chart-line" aria-hidden /> Prometheus metrics
        </h2>
        <p className={styles.subtitle}>
          Dedicated scrape server on port 9090 (separate from the management API). Use{' '}
          <code className="mono">/metrics</code> in Prometheus jobs and ServiceMonitor.
        </p>
      </div>

      {!enabled ? (
        <p className={styles.disabledNote}>
          Metrics server is disabled (<code className="mono">metrics_enabled=false</code> or{' '}
          <code className="mono">PERTISK_METRICS_ENABLED=false</code>).
        </p>
      ) : null}

      <div className={styles.grid}>
        <div className={styles.card}>
          <span className={styles.cardLabel}>Endpoints</span>
          <div className={styles.endpointList}>
            {[
              { key: 'metrics', label: 'Metrics', url: metricsUrl },
              { key: 'health', label: 'Health', url: healthUrl },
              { key: 'legacy', label: 'Legacy (management)', url: legacyUrl },
            ].map(({ key, label, url }) => (
              <div key={key} className={styles.endpointRow}>
                <span className={styles.endpointKey}>{label}</span>
                <span className={`mono ${styles.endpointUrl}`} title={url}>
                  {url}
                </span>
                <button
                  type="button"
                  className={styles.copyBtn}
                  onClick={() => copyUrl(url, key)}
                  title={`Copy ${label} URL`}
                >
                  <i className={copied === key ? 'fas fa-check' : 'fas fa-copy'} aria-hidden />
                  {copied === key ? ' Copied' : ' Copy'}
                </button>
              </div>
            ))}
          </div>
          <p className={styles.hint}>
            Override with <code className="mono">PERTISK_METRICS_ADDR</code> or{' '}
            <code className="mono">metrics_port</code> in ingress.json / Helm{' '}
            <code className="mono">controller.config</code>.
          </p>
        </div>

        <div className={styles.card}>
          <span className={styles.cardLabel}>Key series</span>
          <div className={styles.chips}>
            {PROMETHEUS_SERIES.map((name) => (
              <span key={name} className={styles.chip}>
                {name}
              </span>
            ))}
          </div>
          <p className={styles.hint}>
            Admin UI charts use <code className="mono">GET /api/stats</code>; Prometheus scrapes raw exposition from{' '}
            <code className="mono">:9090/metrics</code>.
          </p>
        </div>
      </div>
    </section>
  );
}
