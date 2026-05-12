import { useCallback, useEffect, useState, ChangeEvent, useMemo } from 'react';
import { api, type CertificateRow } from '@/api/client';
import { useToast } from '@/context/ToastContext';
import { useSslJobs, formatAcmeSslPhase } from '@/context/SslJobContext';
import styles from './Certificates.module.css';

type CertificatesCache = {
  rows: CertificateRow[];
};

let certificatesCache: CertificatesCache | null = null;

function em(value: string | undefined | null): string {
  const s = (value ?? '').trim();
  return s.length ? s : '—';
}

function readFileAsText(file: File | null): Promise<string> {
  if (!file) return Promise.resolve('');
  return new Promise((resolve, reject) => {
    const r = new FileReader();
    r.onload = () => resolve(typeof r.result === 'string' ? r.result : '');
    r.onerror = () => reject(new Error('Failed to read file'));
    r.readAsText(file);
  });
}

export default function Certificates() {
  const toast = useToast();
  const { jobsByHost, lastPush } = useSslJobs();
  const sslJobEntries = useMemo(
    () => Object.values(jobsByHost).sort((a, b) => (b.updated_at_ms ?? 0) - (a.updated_at_ms ?? 0)),
    [jobsByHost]
  );
  const [rows, setRows] = useState<CertificateRow[]>(() => certificatesCache?.rows ?? []);
  const [loading, setLoading] = useState(() => certificatesCache == null);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [importError, setImportError] = useState<string | null>(null);
  const [certPem, setCertPem] = useState('');
  const [keyPem, setKeyPem] = useState('');
  const [importing, setImporting] = useState(false);
  const [showImportModal, setShowImportModal] = useState(false);
  const [importMode, setImportMode] = useState<'new' | 'listener' | 'existing'>('new');
  const [targetCertId, setTargetCertId] = useState<string | null>(null);
  const [showLabelModal, setShowLabelModal] = useState(false);
  const [editingLabel, setEditingLabel] = useState<string | null>(null);
  const [labelValue, setLabelValue] = useState('');
  const [labelError, setLabelError] = useState<string | null>(null);
  const [labelSaving, setLabelSaving] = useState(false);

  const load = useCallback((opts?: { silent?: boolean }) => {
    const silent = opts?.silent === true;
    if (!silent) {
      setLoading(true);
    }
    setLoadError(null);
    api.certificates
      .list()
      .then((list) => {
        const nextRows = Array.isArray(list) ? list : [];
        setRows(nextRows);
        certificatesCache = { rows: nextRows };
      })
      .catch((e: unknown) => {
        setLoadError(e instanceof Error ? e.message : 'Failed to load certificates');
        if (certificatesCache == null) {
          setRows([]);
        }
      })
      .finally(() => {
        if (!silent) {
          setLoading(false);
        }
      });
  }, []);

  useEffect(() => {
    load({ silent: certificatesCache != null });
  }, [load]);

  useEffect(() => {
    if (!lastPush) return;
    if (String(lastPush.phase ?? '') !== 'complete') return;
    const timer = window.setTimeout(() => {
      load({ silent: true });
    }, 1000);
    return () => window.clearTimeout(timer);
  }, [lastPush, load]);

  const closeImportModal = useCallback(() => {
    setShowImportModal(false);
    setCertPem('');
    setKeyPem('');
    setImportError(null);
    setImportMode('new');
    setTargetCertId(null);
  }, []);

  const openImportModal = useCallback((mode: 'new' | 'listener' | 'existing' = 'new', certId?: string) => {
    setImportMode(mode);
    setTargetCertId(certId ?? null);
    setImportError(null);
    setCertPem('');
    setKeyPem('');
    setShowImportModal(true);
  }, []);

  function openAddLabelModal() {
    setEditingLabel(null);
    setLabelValue('');
    setLabelError(null);
    setShowLabelModal(true);
  }

  function openEditLabelModal(row: CertificateRow) {
    setEditingLabel(row.id);
    setLabelValue((row.domain ?? row.hosts?.[0] ?? row.id).trim());
    setLabelError(null);
    setShowLabelModal(true);
  }

  function closeLabelModal() {
    setShowLabelModal(false);
    setEditingLabel(null);
    setLabelValue('');
    setLabelError(null);
  }

  async function submitLabel() {
    setLabelSaving(true);
    setLabelError(null);
    try {
      if (!labelValue.trim()) throw new Error('Certificate id is required');
      if (!editingLabel) {
        await api.certificates.createLabel(labelValue);
        toast.success('Certificate added.');
      } else {
        await api.certificates.updateLabel(editingLabel, labelValue);
        toast.success('Certificate updated.');
      }
      closeLabelModal();
      await load();
    } catch (e: unknown) {
      const msg = e instanceof Error ? e.message : 'Failed to save label';
      setLabelError(msg);
      toast.error(msg);
    } finally {
      setLabelSaving(false);
    }
  }

  async function deleteLabel(row: CertificateRow) {
    if (!confirm(`Delete certificate "${row.id}"?`)) return;
    try {
      await api.certificates.deleteLabel(row.id);
      toast.success('Certificate deleted.');
      await load();
    } catch (e: unknown) {
      toast.error(e instanceof Error ? e.message : 'Failed to delete label');
    }
  }

  async function deleteListenerTls() {
    if (!confirm('Delete listener TLS from config?')) return;
    try {
      await api.certificates.deleteListenerTls();
      toast.success('Listener TLS removed from config.');
      await load();
    } catch (e: unknown) {
      toast.error(e instanceof Error ? e.message : 'Failed to delete listener TLS');
    }
  }

  useEffect(() => {
    if (!showImportModal) return;
    function onKey(e: KeyboardEvent) {
      if (e.key === 'Escape') closeImportModal();
    }
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [showImportModal, closeImportModal]);

  async function onCertFile(e: ChangeEvent<HTMLInputElement>) {
    const t = await readFileAsText(e.target.files?.[0] ?? null);
    if (t) setCertPem(t);
    e.target.value = '';
  }

  async function onKeyFile(e: ChangeEvent<HTMLInputElement>) {
    const t = await readFileAsText(e.target.files?.[0] ?? null);
    if (t) setKeyPem(t);
    e.target.value = '';
  }

  async function submitImport() {
    setImporting(true);
    setImportError(null);
    try {
      const res = importMode === 'listener'
        ? await api.certificates.importListenerPem(certPem.trim(), keyPem.trim())
        : importMode === 'existing' && targetCertId
          ? await api.certificates.updatePem(targetCertId, certPem.trim(), keyPem.trim())
          : await api.certificates.importPem(certPem.trim(), keyPem.trim());
      toast.success(
        res.notice ??
          (importMode === 'listener'
            ? 'Listener TLS updated.'
            : importMode === 'existing'
              ? 'Certificate PEM updated.'
              : 'TLS certificate imported as a new certificate.'),
      );
      closeImportModal();
      await load();
    } catch (e: unknown) {
      const msg = e instanceof Error ? e.message : 'Import failed';
      setImportError(msg);
      toast.error(msg);
    } finally {
      setImporting(false);
    }
  }

  return (
    <section className={styles.section}>
      {loadError && (
        <div className="error-banner">
          <i className="fas fa-exclamation-circle" aria-hidden />
          {loadError}
        </div>
      )}

      <div className="page-actions">
        <div className={styles.headerActions}>
          <div className={styles.toolbar}>
            <button
              type="button"
              className={styles.btnSecondary}
              onClick={() => load()}
              disabled={loading}
            >
              <i className="fas fa-sync-alt" aria-hidden /> Refresh
            </button>
            <button
              type="button"
              className={styles.btnPrimary}
              onClick={() => openImportModal()}
            >
              <i className="fas fa-file-import" aria-hidden /> Import TLS…
            </button>
          </div>
        </div>
      </div>

      {sslJobEntries.length > 0 && (
        <div className={styles.sslJobsLive} role="status" aria-live="polite">
          <div className={styles.sslJobsLiveTitle}>
            <i className="fas fa-bolt" aria-hidden /> Auto-SSL in progress
          </div>
          <ul className={styles.sslJobsLiveList}>
            {sslJobEntries.map((j) => (
              <li key={j.host} className={styles.sslJobsLiveItem}>
                <span className={styles.sslJobsHost}>{j.host}</span>
                <span className={j.phase === 'error' ? styles.sslJobsPhaseErr : styles.sslJobsPhase}>
                  {formatAcmeSslPhase(j.phase)}
                </span>
                <span className={styles.sslJobsMsg} title={j.message}>
                  {j.message?.trim() ? j.message : '—'}
                </span>
              </li>
            ))}
          </ul>
        </div>
      )}

      {loading ? (
        <div className="spinner" />
      ) : rows.length === 0 ? (
        <div className={styles.emptyState}>
          <i className="fas fa-certificate" aria-hidden />
          <h3 className={styles.emptyTitle}>No certificates</h3>
          <button type="button" className={styles.btnPrimary} onClick={() => openImportModal()}>
            <i className="fas fa-file-import" aria-hidden /> Import TLS…
          </button>
        </div>
      ) : (
        <div className={styles.tableWrap}>
          <div style={{ overflowX: 'auto' }}>
              <table className={styles.certTable}>
              <thead>
                <tr>
                  <th scope="col">Id</th>
                  <th scope="col">Domain</th>
                  <th scope="col">Names</th>
                  <th scope="col">Issuer</th>
                  <th scope="col">Challenge</th>
                  <th scope="col">Valid from</th>
                  <th scope="col">Expires</th>
                  <th scope="col">Next renew</th>
                  <th scope="col">Sites</th>
                  <th scope="col" className={styles.actionsCol}>
                    Actions
                  </th>
                </tr>
              </thead>
              <tbody>
                {rows.map((row, idx) => (
                  <tr key={row.id}>
                    <td className="mono">{idx + 1}</td>
                    <td className={styles.names}>{em(row.domain ?? row.hosts?.[0])}</td>
                    <td className={styles.names}>
                      {row.hosts?.length ? row.hosts.join(', ') : '—'}
                    </td>
                    <td>{em(row.issuer)}</td>
                    <td>{em(row.challenge)}</td>
                    <td className={styles.mono}>{em(row.created_at)}</td>
                    <td className={styles.mono}>{em(row.expires_at)}</td>
                    <td>{em(row.next_renew)}</td>
                    <td>{!row.sites?.length ? '—' : row.sites.join(', ')}</td>
                    <td className={styles.actionsCell}>
                      <div className={styles.rowActions}>
                        {row.source_type === 'tls_listener' ? (
                          <button
                            type="button"
                            className={styles.rowActionBtn}
                            onClick={() => openImportModal('listener')}
                            title="Replace TLS certificate"
                            aria-label={`Replace TLS certificate ${row.id}`}
                          >
                            <i className="fas fa-file-import" aria-hidden />
                          </button>
                        ) : row.source_type === 'imported_pem' ? (
                          <button
                            type="button"
                            className={styles.rowActionBtn}
                            onClick={() => openImportModal('existing', row.id)}
                            title="Replace certificate PEM"
                            aria-label={`Replace certificate PEM ${row.id}`}
                          >
                            <i className="fas fa-file-import" aria-hidden />
                          </button>
                        ) : null}
                        <button
                          type="button"
                          className={`${styles.rowActionBtn} ${styles.rowActionDanger}`}
                          onClick={() => (row.source_type === 'tls_listener' ? void deleteListenerTls() : void deleteLabel(row))}
                          title="Delete"
                          aria-label={`Delete certificate ${row.id}`}
                        >
                          <i className="fas fa-trash" aria-hidden />
                        </button>
                      </div>
                    </td>
                  </tr>
                ))}
              </tbody>
              </table>
        </div>
        </div>
      )}

      {showImportModal && (
        <div
          className={styles.modalBackdrop}
          role="presentation"
          onClick={(e) => {
            if (e.target === e.currentTarget) closeImportModal();
          }}
        >
          <div className={styles.modal} role="dialog" aria-modal="true" aria-labelledby="import-tls-title">
            <div className={styles.modalHeader}>
              <h2 id="import-tls-title">
                {importMode === 'listener'
                  ? 'Update listener TLS'
                  : importMode === 'existing'
                    ? 'Update certificate PEM'
                    : 'Import new TLS certificate'}
              </h2>
              <button type="button" className={styles.modalClose} onClick={closeImportModal} aria-label="Close">
                ×
              </button>
            </div>
            <div className={styles.modalBody}>
              {importError && (
                <div className="error-banner" style={{ marginBottom: 12 }}>
                  <i className="fas fa-exclamation-circle" aria-hidden />
                  {importError}
                </div>
              )}
              <p className={styles.modalHint}>
                {importMode === 'listener'
                  ? 'Paste PEM or choose files. Listener TLS files are updated in running config.'
                  : importMode === 'existing'
                    ? 'Paste PEM or choose files. Selected certificate PEM/key will be replaced.'
                    : 'Paste PEM or choose files. A new certificate entry will be created and available for site selection.'}
              </p>
              <label className={styles.fieldLabel}>
                Certificate PEM
                <input type="file" accept=".pem,.crt,.txt" onChange={onCertFile} className={styles.fileInput} />
                <textarea
                  value={certPem}
                  onChange={(e) => setCertPem(e.target.value)}
                  rows={8}
                  className={styles.textarea}
                  placeholder="-----BEGIN CERTIFICATE-----"
                  spellCheck={false}
                />
              </label>
              <label className={styles.fieldLabel}>
                Private key PEM
                <input type="file" accept=".pem,.key,.txt" onChange={onKeyFile} className={styles.fileInput} />
                <textarea
                  value={keyPem}
                  onChange={(e) => setKeyPem(e.target.value)}
                  rows={6}
                  className={styles.textarea}
                  placeholder="-----BEGIN PRIVATE KEY-----"
                  spellCheck={false}
                />
              </label>
              <div className={styles.modalActions}>
                <button
                  type="button"
                  className={styles.btnSecondary}
                  onClick={closeImportModal}
                  disabled={importing}
                >
                  Cancel
                </button>
                <button
                  type="button"
                  className={styles.btnPrimary}
                  onClick={() => void submitImport()}
                  disabled={importing || !certPem.trim() || !keyPem.trim()}
                >
                  {importing
                    ? 'Importing…'
                    : importMode === 'listener'
                      ? 'Update TLS'
                      : importMode === 'existing'
                        ? 'Update PEM'
                        : 'Import TLS'}
                </button>
              </div>
            </div>
          </div>
        </div>
      )}
    </section>
  );
}
