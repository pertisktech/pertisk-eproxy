import FaIcon from "@/components/FaIcon";
import { useEffect, useMemo, useState, useCallback } from 'react';
import { api, type HelmHistoryEntry, type HelmHistoryResponse, type ManagementInfo } from '@/api/client';
import { formatDateTime } from '@/utils/dateFormat';
import YamlEditor from '@/components/YamlEditor';
import styles from './Helm.module.css';

function normalizeHistory(history: HelmHistoryResponse | null): HelmHistoryEntry[] {
  if (!history) return [];
  const raw = history.history;
  if (Array.isArray(raw)) return raw;
  return [];
}

interface RevisionCardProps {
  entry: HelmHistoryEntry;
  isCurrent: boolean;
}

function RevisionCard({ entry, isCurrent }: RevisionCardProps) {
  const [expanded, setExpanded] = useState(false);
  const [values, setValues] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const handleToggle = useCallback(async () => {
    if (expanded) {
      setExpanded(false);
      return;
    }
    setExpanded(true);
    if (values !== null || entry.revision === undefined) return;
    
    setLoading(true);
    setError(null);
    try {
      const resp = await api.helmValues(entry.revision);
      setValues(resp.values);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Failed to load values');
    } finally {
      setLoading(false);
    }
  }, [expanded, values, entry.revision]);

  return (
    <div className={`${styles.revisionCard} ${isCurrent ? styles.revisionCardCurrent : ''}`}>
      <button
        type="button"
        className={styles.revisionHeader}
        onClick={handleToggle}
        aria-expanded={expanded}
      >
        <div className={styles.revisionMeta}>
          <span className={styles.revisionNumber}>
            <FaIcon className={`fas fa-code-branch ${styles.revisionIcon}`} aria-hidden />
            Revision {entry.revision ?? '—'}
          </span>
          {isCurrent && <span className={styles.currentBadge}>Current</span>}
          <span className={`${styles.statusBadge} ${entry.status === 'deployed' ? styles.statusDeployed : ''}`}>
            {entry.status ?? '—'}
          </span>
        </div>
        <div className={styles.revisionInfo}>
          <span className={styles.chartInfo}>
            <FaIcon className="fas fa-box" aria-hidden /> {entry.chart ?? '—'}
          </span>
          <span className={styles.versionInfo}>
            <FaIcon className="fas fa-tag" aria-hidden /> {entry.app_version ?? '—'}
          </span>
          <span className={styles.dateInfo}>
            <FaIcon className="fas fa-clock" aria-hidden /> {entry.updated ? formatDateTime(entry.updated) : '—'}
          </span>
        </div>
        <FaIcon className={`fas fa-chevron-${expanded ? 'up' : 'down'} ${styles.expandIcon}`} aria-hidden />
      </button>
      
      {expanded && (
        <div className={styles.revisionBody}>
          {entry.description && (
            <div className={styles.description}>
              <FaIcon className="fas fa-info-circle" aria-hidden /> {entry.description}
            </div>
          )}
          
          <div className={styles.yamlSection}>
            <div className={styles.yamlHeader}>
              <FaIcon className="fas fa-file-code" aria-hidden />
              Values YAML
            </div>
            {loading && (
              <div className={styles.yamlLoading}>
                <FaIcon className="fas fa-spinner fa-spin" aria-hidden /> Loading values…
              </div>
            )}
            {error && (
              <div className={styles.yamlError}>
                <FaIcon className="fas fa-exclamation-triangle" aria-hidden /> {error}
              </div>
            )}
            {!loading && !error && values !== null && (
              <div className={styles.yamlViewer}>
                <YamlEditor value={values} height={400} readOnly />
              </div>
            )}
          </div>
        </div>
      )}
    </div>
  );
}

export default function Helm() {
  const [history, setHistory] = useState<HelmHistoryResponse | null>(null);
  const [management, setManagement] = useState<ManagementInfo | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    async function load() {
      try {
        const [hist, mgmt] = await Promise.all([api.helmHistory(), api.management()]);
        if (!cancelled) {
          setHistory(hist);
          setManagement(mgmt);
          setError(null);
        }
      } catch (e) {
        if (!cancelled) setError(e instanceof Error ? e.message : 'Failed to load Helm history');
      } finally {
        if (!cancelled) setLoading(false);
      }
    }
    load();
    const t = setInterval(load, 30000);
    return () => {
      cancelled = true;
      clearInterval(t);
    };
  }, []);

  const historyRows = useMemo(() => {
    const rows = normalizeHistory(history);
    return [...rows].sort((a, b) => (b.revision ?? 0) - (a.revision ?? 0));
  }, [history]);

  const current = historyRows[0] ?? null;

  return (
    <section className={styles.section}>
      {error && (
        <div className={styles.error}>
          <FaIcon className="fas fa-exclamation-triangle" aria-hidden />
          {error}
        </div>
      )}

      {loading && (
        <div className={styles.loading}>
          <FaIcon className="fas fa-spinner fa-spin" aria-hidden />
          Loading…
        </div>
      )}

      {!loading && !error && (
        <>
          <div className={styles.summaryGrid}>
            <div className={styles.summaryCard}>
              <span className={styles.summaryLabel}>Release</span>
              <span className={styles.summaryValue}>{history?.release ?? '—'}</span>
              <span className={styles.summaryHint}>{history?.namespace ?? 'default'}</span>
            </div>
            <div className={styles.summaryCard}>
              <span className={styles.summaryLabel}>Running version</span>
              <span className={styles.summaryValue}>{management?.version ?? '—'}</span>
              <span className={styles.summaryHint}>From management API</span>
            </div>
            <div className={styles.summaryCard}>
              <span className={styles.summaryLabel}>Current revision</span>
              <span className={styles.summaryValue}>{current?.revision ?? '—'}</span>
              <span className={styles.summaryHint}>{current?.status ?? '—'}</span>
            </div>
            <div className={styles.summaryCard}>
              <span className={styles.summaryLabel}>Chart / App</span>
              <span className={styles.summaryValue}>{current?.chart ?? '—'}</span>
              <span className={styles.summaryHint}>{current?.app_version ?? '—'}</span>
            </div>
          </div>

          <div className={styles.revisionsSection}>
            <h3 className={styles.revisionsTitle}>
              <FaIcon className="fas fa-history" aria-hidden />
              Revision History
            </h3>
            <div className={styles.revisionsList}>
              {historyRows.map((row, idx) => (
                <RevisionCard
                  key={row.revision ?? row.updated ?? `row-${idx}`}
                  entry={row}
                  isCurrent={idx === 0}
                />
              ))}
              {historyRows.length === 0 && (
                <div className={styles.empty}>
                  <FaIcon className="fas fa-inbox" aria-hidden />
                  No Helm history data
                </div>
              )}
            </div>
          </div>
        </>
      )}
    </section>
  );
}
