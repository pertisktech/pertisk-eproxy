import FaIcon from "@/components/FaIcon";
import { useEffect, useState, FormEvent, useMemo } from 'react';
import { createPortal } from 'react-dom';
import {
  api,
  type DnsProviderRow,
  type DnsProviderType,
  type SupportedDnsProvider,
  type SupportedDnsProviderField,
} from '@/api/client';
import ConfirmDialog from '@/components/ConfirmDialog';
import Pagination from '@/components/Pagination';
import { usePageSize } from '@/utils/usePageSize';
import { useToast } from '@/context/ToastContext';
import styles from './DnsProviders.module.css';

const DNS_LABEL_ID = 'label';

export default function DnsProviders() {
  const [list, setList] = useState<DnsProviderRow[]>([]);
  const [supported, setSupported] = useState<SupportedDnsProvider[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [showForm, setShowForm] = useState(false);
  const [editingId, setEditingId] = useState<string | null>(null);
  const [formName, setFormName] = useState('');
  const [formType, setFormType] = useState<DnsProviderType>('');
  const [formCreds, setFormCreds] = useState<Record<string, string>>({});
  const [fieldVisibility, setFieldVisibility] = useState<Record<string, boolean>>({});
  const [formError, setFormError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);
  const pageSize = usePageSize();
  const [page, setPage] = useState(1);
  const [deleteConfirmRow, setDeleteConfirmRow] = useState<DnsProviderRow | null>(null);
  const [deletingId, setDeletingId] = useState<string | null>(null);
  const toast = useToast();

  const selectedProvider = supported.find((p) => p.id === formType);
  const supportedIds = useMemo(() => new Set(supported.map((p) => p.id)), [supported]);
  const formTypeUnknown = Boolean(formType && !supportedIds.has(formType));

  const totalPages = Math.max(1, Math.ceil(list.length / pageSize));
  useEffect(() => {
    setPage((p) => Math.max(1, Math.min(totalPages, p)));
  }, [totalPages]);

  const startIndex = (page - 1) * pageSize;
  const endIndexExclusive = startIndex + pageSize;
  const pagedList = list.slice(startIndex, endIndexExclusive);

  function load(): Promise<DnsProviderRow[]> {
    setLoading(true);
    setError(null);
    return Promise.all([api.dnsProviders.list(), api.dnsProviders.supported()])
      .then(([rows, sup]) => {
        const safeRows = Array.isArray(rows) ? rows : [];
        setList(safeRows);
        setSupported(Array.isArray(sup) ? sup : []);
        return safeRows;
      })
      .catch((e) => {
        const msg = e instanceof Error ? e.message : 'Failed to load';
        setError(msg);
        return [];
      })
      .finally(() => setLoading(false));
  }

  /** Running BEAM older than structured DNS parsing returns fewer rows from GET /api/config than we PUT. */
  async function reconcileListAfterSave(optimisticRows: DnsProviderRow[]) {
    const serverRows = await load();
    if (optimisticRows.length > serverRows.length) {
      toast.info(
        'Server reported fewer DNS providers than we saved. Fully restart the proxy (stop `make run` / the release, then start again) so the latest `pertisk_eproxy_config` is loaded. The list shows your last save. Avoid POST /api/reload unless you intend to reload config from disk (that drops in-memory changes).',
        12000,
      );
      setList(optimisticRows);
    }
  }

  useEffect(() => {
    load();
  }, []);

  useEffect(() => {
    if (!showForm) return;
    const root = document.documentElement;
    root.classList.add('eproxy-scroll-lock');
    return () => {
      root.classList.remove('eproxy-scroll-lock');
    };
  }, [showForm]);

  function openAdd() {
    setEditingId(null);
    setFormName('');
    setFormType(supported.length ? supported[0].id : '');
    setFormCreds({});
    setFieldVisibility({});
    setFormError(null);
    setShowForm(true);
  }

  function openEdit(row: DnsProviderRow) {
    setEditingId(row.id);
    setFormName(row.name);
    setFormType(row.provider_type);
    setFormCreds(row.credentials && typeof row.credentials === 'object' ? { ...row.credentials } : {});
    setFieldVisibility({});
    setFormError(null);
    setShowForm(true);
  }

  function loadFullThenEdit(id: string) {
    api.dnsProviders
      .get(id)
      .then((row) => openEdit(row))
      .catch((e) => setFormError(e instanceof Error ? e.message : 'Failed to load provider'));
  }

  function setCred(key: string, value: string) {
    setFormCreds((prev) => ({ ...prev, [key]: value }));
  }

  function toggleFieldVisibility(key: string) {
    setFieldVisibility((prev) => ({ ...prev, [key]: !prev[key] }));
  }

  function buildCredentials(): Record<string, string> | undefined {
    if (!selectedProvider) return undefined;
    const out: Record<string, string> = {};
    for (const field of selectedProvider.fields) {
      const v = formCreds[field.key]?.trim();
      if (v) out[field.key] = v;
    }
    return Object.keys(out).length ? out : undefined;
  }

  function handleSubmit(e: FormEvent) {
    e.preventDefault();
    setFormError(null);
    const name = formName.trim();
    const provider_type = formType.trim();
    if (!name) {
      setFormError('Name is required');
      return;
    }
    if (!provider_type) {
      setFormError('Provider type is required');
      return;
    }
    if (!editingId && !supportedIds.has(provider_type)) {
      setFormError('Choose a provider type from the list.');
      return;
    }
    const credentials = buildCredentials();
    if (selectedProvider?.fields.some((f) => f.required && !formCreds[f.key]?.trim())) {
      setFormError('All required fields must be filled');
      return;
    }
    setSaving(true);
    if (editingId) {
      api.dnsProviders
        .put(editingId, name, provider_type, credentials)
        .then(async (optimisticRows) => {
          setShowForm(false);
          setList(optimisticRows);
          setPage(1);
          toast.success('DNS provider updated.');
          await reconcileListAfterSave(optimisticRows);
        })
        .catch((e) => setFormError(e instanceof Error ? e.message : 'Failed to update'))
        .finally(() => setSaving(false));
    } else {
      api.dnsProviders
        .create(name, provider_type, credentials)
        .then(async (optimisticRows) => {
          setShowForm(false);
          setList(optimisticRows);
          setPage(1);
          toast.success('DNS provider added.');
          await reconcileListAfterSave(optimisticRows);
        })
        .catch((e) => setFormError(e instanceof Error ? e.message : 'Failed to create'))
        .finally(() => setSaving(false));
    }
  }

  function openDeleteConfirm(row: DnsProviderRow) {
    setDeleteConfirmRow(row);
  }

  function remove(id: string) {
    setDeleteConfirmRow(null);
    setDeletingId(id);
    api.dnsProviders
      .delete(id)
      .then(async (optimisticRows) => {
        setList(optimisticRows);
        toast.success('DNS provider removed.');
        await reconcileListAfterSave(optimisticRows);
      })
      .catch((e) => toast.error(e instanceof Error ? e.message : 'Failed to delete'))
      .finally(() => setDeletingId(null));
  }

  function getProviderDisplayName(providerType: DnsProviderType): string {
    const p = supported.find((s) => s.id === providerType);
    return p ? p.name : providerType;
  }

  if (loading && list.length === 0) {
    return (
      <section className={styles.section}>
        <p className={styles.muted}>Loading…</p>
      </section>
    );
  }

  if (error) {
    return (
      <section className={styles.section}>
        <p className={styles.error}>{error}</p>
        <button type="button" className={styles.btnSecondary} onClick={load}>
          Retry
        </button>
      </section>
    );
  }

  return (
    <section className={styles.section}>
      <div className="page-actions">
        <button type="button" className={styles.btnPrimary} onClick={openAdd}>
          <FaIcon className="fas fa-plus" aria-hidden /> Add DNS provider
        </button>
      </div>

      {list.length === 0 ? (
        <div className={styles.emptyState}>
          <FaIcon className="fas fa-server" size={48} aria-hidden />
          <h3 className={styles.emptyTitle}>No DNS providers</h3>
          <button type="button" className={styles.btnPrimary} onClick={openAdd}>
            <FaIcon className="fas fa-plus" aria-hidden /> Add DNS provider
          </button>
        </div>
      ) : (
        <div className={styles.tableWrap}>
          <table className={styles.table}>
            <thead>
              <tr>
                <th>Name</th>
                <th>Type</th>
                <th className={`${styles.actionsCol} ${styles.actionsTh}`} scope="col">
                  Actions
                </th>
              </tr>
            </thead>
            <tbody>
              {pagedList.map((row) => {
                const rawType = row.provider_type ?? '';
                const typeLabel =
                  rawType === DNS_LABEL_ID || rawType === ''
                    ? 'Label'
                    : getProviderDisplayName(rawType);
                return (
                  <tr key={row.id} className={styles.tableRow}>
                    <td className={styles.nameCell}>
                      <span className={styles.nameText}>{row.name}</span>
                    </td>
                    <td>
                      <span className={styles.typeCell}>{typeLabel}</span>
                    </td>
                    <td className={`${styles.actionsCol} ${styles.actionsColTd}`}>
                      <div className={styles.rowActions}>
                        <button
                          type="button"
                          className={styles.iconBtn}
                          onClick={() => loadFullThenEdit(row.id)}
                          aria-label={`Edit ${row.name}`}
                          title="Edit"
                        >
                          <FaIcon className="fas fa-edit" aria-hidden />
                        </button>
                        <button
                          type="button"
                          className={`${styles.iconBtn} ${styles.iconBtnDanger}`}
                          onClick={() => openDeleteConfirm(row)}
                          aria-label={`Remove ${row.name}`}
                          title="Remove"
                        >
                          <FaIcon className="fas fa-trash" aria-hidden />
                        </button>
                      </div>
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}

      <Pagination
        totalItems={list.length}
        pageSize={pageSize}
        page={page}
        onPageChange={setPage}
        ariaLabel="DNS providers pagination"
      />

      {showForm &&
        createPortal(
          <div
            className={styles.modalBackdrop}
            role="presentation"
            onClick={(e) => {
              if (e.target === e.currentTarget) setShowForm(false);
            }}
          >
          <div className={styles.modal} role="dialog" aria-modal="true">
            <div className={styles.modalHeader}>
              <h2>
                <FaIcon className={editingId ? 'fas fa-pen-to-square' : 'fas fa-plus'} aria-hidden />{' '}
                {editingId ? 'Edit DNS provider' : 'Add DNS provider'}
              </h2>
              <button type="button" className={styles.modalClose} onClick={() => setShowForm(false)} aria-label="Close">
                <FaIcon className="fas fa-times" aria-hidden />
              </button>
            </div>
            <form onSubmit={handleSubmit} className={styles.modalForm} autoComplete="off">
              <label className={styles.label}>
                Name
                <input
                  type="text"
                  name="dns-provider-name"
                  value={formName}
                  onChange={(e) => setFormName(e.target.value)}
                  placeholder="e.g. My Cloudflare Account"
                  className={styles.input}
                  autoComplete="off"
                  required
                />
              </label>
              <label className={styles.label}>
                Provider type
                <select
                  name="dns-provider-type"
                  value={formType}
                  onChange={(e) => {
                    setFormType(e.target.value);
                    setFormCreds({});
                  }}
                  className={styles.input}
                  required
                  disabled={!!editingId}
                  autoComplete="off"
                >
                  {!formType && <option value="">Select a provider…</option>}
                  {formTypeUnknown && (
                    <option value={formType}>
                      Unsupported type ({formType}) — upgrade admin or migrate this entry
                    </option>
                  )}
                  {supported.map((p) => (
                    <option key={p.id} value={p.id}>
                      {p.name}
                    </option>
                  ))}
                </select>
              </label>
              {formTypeUnknown && editingId && (
                <p className={styles.formHint} role="status">
                  This provider&apos;s type is not in the current supported list. Type cannot be changed here; add a new
                  provider if you need a supported integration.
                </p>
              )}

              {selectedProvider && selectedProvider.fields.length > 0 && (
                <div className={styles.configBlock}>
                  <h4 className={styles.configBlockTitle}>{selectedProvider.name} configuration</h4>
                  {selectedProvider.fields.map((field) => (
                    <CredentialField
                      key={field.key}
                      field={field}
                      value={formCreds[field.key] ?? ''}
                      onChange={(v) => setCred(field.key, v)}
                      visible={fieldVisibility[field.key]}
                      onToggleVisibility={() => toggleFieldVisibility(field.key)}
                      inputClassName={styles.input}
                      textareaClassName={styles.textarea}
                      labelClassName={styles.label}
                    />
                  ))}
                </div>
              )}

              {formError && <p className={styles.formError}>{formError}</p>}
              <div className={styles.modalActions}>
                <button type="button" className={styles.btnSecondary} onClick={() => setShowForm(false)}>
                  Cancel
                </button>
                <button type="submit" className={styles.btnPrimary} disabled={saving}>
                  {saving ? 'Saving…' : editingId ? 'Update' : 'Create'}
                </button>
              </div>
            </form>
          </div>
        </div>,
          document.body,
        )}

      <ConfirmDialog
        open={deleteConfirmRow !== null}
        title="Remove DNS provider?"
        message={
          deleteConfirmRow
            ? `Remove "${deleteConfirmRow.name}"? This cannot be undone.`
            : ''
        }
        primaryLabel="Remove"
        cancelLabel="Cancel"
        variant="danger"
        loading={deletingId === deleteConfirmRow?.id}
        onConfirm={() => deleteConfirmRow && remove(deleteConfirmRow.id)}
        onCancel={() => setDeleteConfirmRow(null)}
      />
    </section>
  );
}

function CredentialField({
  field,
  value,
  onChange,
  visible,
  onToggleVisibility,
  inputClassName,
  textareaClassName,
  labelClassName,
}: {
  field: SupportedDnsProviderField;
  value: string;
  onChange: (v: string) => void;
  visible: boolean;
  onToggleVisibility: () => void;
  inputClassName: string;
  textareaClassName: string;
  labelClassName: string;
}) {
  const isPassword = field.type === 'password';
  const isTextarea = field.type === 'textarea';
  const isSensitiveKey = /token|secret|key|password/i.test(field.key);

  return (
    <label className={labelClassName}>
      {field.label}
      {field.required && ' *'}
      {isTextarea ? (
        <textarea
          name={`dns-provider-${field.key}`}
          value={value}
          onChange={(e) => onChange(e.target.value)}
          placeholder={field.label}
          className={textareaClassName}
          rows={4}
          autoComplete="off"
          required={field.required}
        />
      ) : isPassword ? (
        <div className={styles.passwordWrap}>
          <input
            name={`dns-provider-${field.key}`}
            type={visible ? 'text' : 'password'}
            value={value}
            onChange={(e) => onChange(e.target.value)}
            placeholder={field.label}
            className={inputClassName}
            autoComplete="new-password"
            required={field.required}
          />
          <button
            type="button"
            className={styles.passwordToggle}
            onClick={onToggleVisibility}
            title={visible ? 'Hide' : 'Show'}
            aria-label={visible ? 'Hide password' : 'Show password'}
          >
            <FaIcon className={visible ? 'fas fa-eye-slash' : 'fas fa-eye'} />
          </button>
        </div>
      ) : (
        <input
          type="text"
          name={`dns-provider-${field.key}`}
          value={value}
          onChange={(e) => onChange(e.target.value)}
          placeholder={field.label}
          className={inputClassName}
          autoComplete={isSensitiveKey ? 'new-password' : 'off'}
          required={field.required}
        />
      )}
    </label>
  );
}
