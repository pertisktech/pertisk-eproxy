import { useCallback, useEffect, useState, ChangeEvent, useMemo } from 'react';
import { api, type CertificateRow } from '@/api/client';
import ConfirmDialog from '@/components/ConfirmDialog';
import DataTable from '@/components/DataTable';
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
  const [deleteTarget, setDeleteTarget] = useState<{ type: 'cert'; row: CertificateRow } | { type: 'listener' } | null>(null);
  const [deleting, setDeleting] = useState(false);

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
    setDeleting(true);
    try {
      await api.certificates.deleteLabel(row.id);
      toast.success('Certificate deleted.');
      setDeleteTarget(null);
      await load();
    } catch (e: unknown) {
      toast.error(e instanceof Error ? e.message : 'Failed to delete label');
    } finally {
      setDeleting(false);
    }
  }

  async function deleteListenerTls() {
    setDeleting(true);
    try {
      await api.certificates.deleteListenerTls();
      toast.success('Listener TLS removed from config.');
      setDeleteTarget(null);
      await load();
    } catch (e: unknown) {
      toast.error(e instanceof Error ? e.message : 'Failed to delete listener TLS');
    } finally {
      setDeleting(false);
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
        <DataTable
          columns={[
            {
              header: 'Id',
              render: (_row, index) => <span className="mono">{index + 1}</span>,
            },
            {
              header: 'Domain',
              render: (row) => em(row.domain ?? row.hosts?.[0]),
              cellClassName: styles.names,
            },
            {
              header: 'Names',
              render: (row) => (row.hosts?.length ? row.hosts.join(', ') : '—'),
              cellClassName: styles.names,
            },
            {
              header: 'Issuer',
              render: (row) => em(row.issuer),
            },
            {
              header: 'Challenge',
              render: (row) => em(row.challenge),
            },
            {
              header: 'Valid from',
              render: (row) => em(row.created_at),
              cellClassName: styles.mono,
            },
            {
              header: 'Expires',
              render: (row) => em(row.expires_at),
              cellClassName: styles.mono,
            },
            {
              header: 'Next renew',
              render: (row) => em(row.next_renew),
            },
            {
              header: 'Sites',
              render: (row) => (!row.sites?.length ? '—' : row.sites.join(', ')),
            },
            {
              header: 'Actions',
              headerClassName: styles.actionsCol,
              cellClassName: styles.actionsCell,
              render: (row) => (
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
                    onClick={() =>
                      setDeleteTarget(
                        row.source_type === 'tls_listener' ? { type: 'listener' } : { type: 'cert', row },
                      )
                    }
                    title="Delete"
                    aria-label={`Delete certificate ${row.id}`}
                  >
                    <i className="fas fa-trash" aria-hidden />
                  </button>
                </div>
              ),
            },
          ]}
          data={rows}
          rowKey={(row) => row.id}
          isLoading={loading}
          error={loadError}
          emptyMessage="No certificates"
          totalLabel={`Total: ${rows.length} certificate${rows.length === 1 ? '' : 's'}`}
        />
      )}

      {showImportModal && (
        <div
          className={styles.modalBackdrop}
          role="presentation"
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
                  ? 'Paste PEM or choose files.'
                  : importMode === 'existing'
                    ? 'Paste PEM or choose files.'
                    : 'Paste PEM or choose files.'}
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

      <ConfirmDialog
        open={deleteTarget !== null}
        title={deleteTarget?.type === 'listener' ? 'Delete listener TLS permanently?' : 'Delete certificate permanently?'}
        message={
          deleteTarget?.type === 'listener'
            ? 'This will permanently remove listener TLS from config. HTTPS listener traffic may stop until TLS is configured again.'
            : deleteTarget?.type === 'cert'
              ? `This will permanently delete certificate "${deleteTarget.row.id}".`
              : ''
        }
        primaryLabel="Delete permanently"
        cancelLabel="Cancel"
        variant="danger"
        loading={deleting}
        onCancel={() => {
          if (!deleting) setDeleteTarget(null);
        }}
        onConfirm={() => {
          if (deleteTarget?.type === 'listener') {
            void deleteListenerTls();
          } else if (deleteTarget?.type === 'cert') {
            void deleteLabel(deleteTarget.row);
          }
        }}
      />
    </section>
  );
}
