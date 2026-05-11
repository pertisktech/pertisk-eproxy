import { useCallback, useEffect, useState, ChangeEvent } from 'react';
import { Link } from 'react-router-dom';
import { api, type CertificateRow } from '@/api/client';
import { useToast } from '@/context/ToastContext';
import styles from './Certificates.module.css';

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
  const [rows, setRows] = useState<CertificateRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [importError, setImportError] = useState<string | null>(null);
  const [certPem, setCertPem] = useState('');
  const [keyPem, setKeyPem] = useState('');
  const [importing, setImporting] = useState(false);
  const [showImportModal, setShowImportModal] = useState(false);
  const [showLabelModal, setShowLabelModal] = useState(false);
  const [editingLabel, setEditingLabel] = useState<string | null>(null);
  const [labelValue, setLabelValue] = useState('');
  const [labelError, setLabelError] = useState<string | null>(null);
  const [labelSaving, setLabelSaving] = useState(false);

  const load = useCallback(() => {
    setLoading(true);
    setLoadError(null);
    api.certificates
      .list()
      .then((list) => {
        setRows(Array.isArray(list) ? list : []);
      })
      .catch((e: unknown) => {
        setLoadError(e instanceof Error ? e.message : 'Failed to load certificates');
        setRows([]);
      })
      .finally(() => setLoading(false));
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  const closeImportModal = useCallback(() => {
    setShowImportModal(false);
    setCertPem('');
    setKeyPem('');
    setImportError(null);
  }, []);

  const openImportModal = useCallback(() => {
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
      const res = await api.certificates.importListenerPem(certPem.trim(), keyPem.trim());
      toast.success(res.notice ?? 'TLS PEM replaced. Paths updated in running config.');
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
              onClick={load}
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
                {rows.map((row) => (
                  <tr key={row.id}>
                    <td className="mono">{row.source_type === 'tls_listener' ? '—' : em(row.id)}</td>
                    <td className={styles.names}>{em(row.domain ?? row.hosts?.[0])}</td>
                    <td className={styles.names}>
                      {row.hosts?.length ? row.hosts.join(', ') : '—'}
                    </td>
                    <td>{em(row.issuer)}</td>
                    <td>{em(row.challenge)}</td>
                    <td className={styles.mono}>{em(row.created_at)}</td>
                    <td className={styles.mono}>{em(row.expires_at)}</td>
                    <td>{em(row.next_renew)}</td>
                    <td>
                      {!row.sites?.length ? (
                        '—'
                      ) : (
                        <span className={styles.siteLinks}>
                          {row.sites.map((h) => (
                            <Link key={h} to={`/sites/${encodeURIComponent(h)}`}>
                              {h}
                            </Link>
                          ))}
                        </span>
                      )}
                    </td>
                    <td className={styles.actionsCell}>
                      {row.source_type === 'tls_listener' ? (
                        <>
                          <button type="button" className={styles.btnSecondary} onClick={() => openImportModal()}>
                            <i className="fas fa-sync-alt" aria-hidden /> Update TLS…
                          </button>
                          <button type="button" className={styles.btnSecondary} onClick={() => void deleteListenerTls()}>
                            <i className="fas fa-trash" aria-hidden /> Delete
                          </button>
                        </>
                      ) : (
                        <>
                          <button type="button" className={styles.btnSecondary} onClick={() => openEditLabelModal(row)}>
                            <i className="fas fa-pen" aria-hidden /> Edit
                          </button>
                          <button type="button" className={styles.btnSecondary} onClick={() => void deleteLabel(row)}>
                            <i className="fas fa-trash" aria-hidden /> Delete
                          </button>
                        </>
                      )}
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
                Import listener TLS
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
                Paste PEM or choose files. Files are written under <code className="mono">priv/tls/</code> on the proxy
                host, and <code className="mono">tls_cert_file</code> / <code className="mono">tls_key_file</code> are
                updated in memory. Restart the proxy to use them on HTTPS.
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
                  {importing ? 'Importing…' : 'Import TLS'}
                </button>
              </div>
            </div>
          </div>
        </div>
      )}
      {showLabelModal && (
        <div className={styles.modalBackdrop} role="presentation" onClick={(e) => e.target === e.currentTarget && closeLabelModal()}>
          <div className={styles.modal} role="dialog" aria-modal="true" aria-labelledby="label-modal-title">
            <div className={styles.modalHeader}>
              <h2 id="label-modal-title">{editingLabel ? 'Update certificate' : 'Import certificate'}</h2>
              <button type="button" className={styles.modalClose} onClick={closeLabelModal} aria-label="Close">
                ×
              </button>
            </div>
            <div className={styles.modalBody}>
              {labelError && (
                <div className="error-banner" style={{ marginBottom: 12 }}>
                  <i className="fas fa-exclamation-circle" aria-hidden />
                  {labelError}
                </div>
              )}
              <label className={styles.fieldLabel}>
                Certificate ID (ACME)
                <input
                  type="text"
                  value={labelValue}
                  onChange={(e) => setLabelValue(e.target.value)}
                  className={styles.textarea}
                  style={{ height: 38, resize: 'none' }}
                  placeholder="example-wildcard-cert"
                />
              </label>
              <div className={styles.modalActions}>
                <button type="button" className={styles.btnSecondary} onClick={closeLabelModal} disabled={labelSaving}>
                  Cancel
                </button>
                <button
                  type="button"
                  className={styles.btnPrimary}
                  onClick={() => void submitLabel()}
                  disabled={labelSaving || !labelValue.trim()}
                >
                  {labelSaving ? 'Saving…' : editingLabel ? 'Update' : 'Import'}
                </button>
              </div>
            </div>
          </div>
        </div>
      )}
    </section>
  );
}
