import { useState } from 'react';
import styles from './HealthProbesPanel.module.css';

const PROBE_ENDPOINTS = [
  { path: '/api/ingress/live', label: 'Ingress liveness', hint: 'Kubernetes livenessProbe (ingress mode)' },
  { path: '/api/ingress/ready', label: 'Ingress readiness', hint: 'Kubernetes readinessProbe (ingress mode)' },
  { path: '/api/health', label: 'Health', hint: 'Aggregated proxy health' },
] as const;

export default function HealthProbesPanel() {
  const base = typeof window !== 'undefined' ? window.location.origin : '';
  const [copied, setCopied] = useState<string | null>(null);

  function copyUrl(url: string, path: string) {
    void navigator.clipboard.writeText(url).then(
      () => {
        setCopied(path);
        setTimeout(() => setCopied(null), 2000);
      },
      () => {},
    );
  }

  return (
    <section className={styles.section}>
      <div className={styles.header}>
        <h2 className={styles.title}>
          <i className="fas fa-heart-pulse" aria-hidden /> Health &amp; probes
        </h2>
        <p className={styles.subtitle}>
          Management API endpoints for Docker HEALTHCHECK, Kubernetes probes, and load balancers.
        </p>
      </div>
      <div className={styles.list}>
        {PROBE_ENDPOINTS.map(({ path, label, hint }) => {
          const url = base ? `${base}${path}` : path;
          return (
            <div key={path} className={styles.row}>
              <div className={styles.main}>
                <span className={styles.label}>{label}</span>
                <span className={`mono ${styles.url}`} title={url}>
                  {url}
                </span>
                <span className={styles.hint}>{hint}</span>
              </div>
              <button
                type="button"
                className={styles.copyBtn}
                onClick={() => copyUrl(url, path)}
                title={`Copy ${label} URL`}
                aria-label={`Copy ${label} URL`}
              >
                <i className={copied === path ? 'fas fa-check' : 'fas fa-copy'} aria-hidden />
                {copied === path ? ' Copied' : ' Copy'}
              </button>
            </div>
          );
        })}
      </div>
    </section>
  );
}
