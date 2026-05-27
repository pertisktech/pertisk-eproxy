import FaIcon from "@/components/FaIcon";
import { useEffect, useState, FormEvent } from 'react';
import { createPortal } from 'react-dom';
import {
  api,
  type DnsProviderRow,
  type SupportedDnsProvider,
  type SupportedDnsProviderField,
} from '@/api/client';
import { getCookieValue, setCookieValue } from '@/auth';
import { formatDateTime } from '@/utils/dateFormat';
import ConfirmDialog from '@/components/ConfirmDialog';
import Pagination from '@/components/Pagination';
import { usePageSize } from '@/utils/usePageSize';
import { useToast } from '@/context/ToastContext';
import styles from './DnsProviders.module.css';

const DNS_LABEL_ID = 'label';
const VIEW_MODE_COOKIE = 'pertisk_dns_providers_view';
const VIEW_MODE_MAX_AGE_SECS = 60 * 60 * 24 * 365;

function normalizeViewMode(value: string | null): 'card' | 'list' {
  return value === 'card' ? 'card' : 'list';
}

function formatValidateDetails(details: Record<string, unknown> | undefined): string[] {
  if (!details || typeof details !== 'object') return ['Validation passed'];
  const entries = Object.entries(details);
  if (entries.length === 0) return ['Validation passed'];
  return entries
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([k, v]) => {
      if (typeof v === 'string' || typeof v === 'number' || typeof v === 'boolean') {
        return `${k}: ${String(v)}`;
      }
      return `${k}: ${JSON.stringify(v)}`;
    });
}

export default function DnsProviders() {
  const [list, setList] = useState<DnsProviderRow[]>([]);
  const [supported, setSupported] = useState<SupportedDnsProvider[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [showForm, setShowForm] = useState(false);
  const [editingId, setEditingId] = useState<string | null>(null);
  const [formName, setFormName] = useState('');
  const [formType, setFormType] = useState<string>('');
  const [formCreds, setFormCreds] = useState<Record<string, string>>({});
  const [fieldVisibility, setFieldVisibility] = useState<Record<string, boolean>>({});
  const [formError, setFormError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);
  const [validating, setValidating] = useState(false);
  const [validateDetails, setValidateDetails] = useState<string[] | null>(null);
  const [dbUnavailable, setDbUnavailable] = useState(false);
  const [viewMode, setViewMode] = useState<'card' | 'list'>(() =>
    normalizeViewMode(getCookieValue(VIEW_MODE_COOKIE))
  );
  const pageSize = usePageSize();
  const [page, setPage] = useState(1);
  type SortKey = 'name' | 'type' | 'created';
  const [sortKey, setSortKey] = useState<SortKey | null>(null);
  const [sortDir, setSortDir] = useState<'asc' | 'desc'>('asc');
  const [deleteConfirmRow, setDeleteConfirmRow] = useState<DnsProviderRow | null>(null);
  const [deletingId, setDeletingId] = useState<string | null>(null);
  const toast = useToast();

  const selectedProvider = supported.find((p) => p.id === formType);

  function toggleSort(nextKey: SortKey) {
    setPage(1);
    setSortKey((prev) => {
      if (prev === nextKey) {
        setSortDir((d) => (d === 'asc' ? 'desc' : 'asc'));
        return prev;
      }
      setSortDir('asc');
      return nextKey;
    });
  }

  function sortIcon(key: SortKey) {
    const active = sortKey === key;
    const cls = !active ? 'fas fa-sort' : sortDir === 'asc' ? 'fas fa-sort-up' : 'fas fa-sort-down';
    return <FaIcon className={cls} aria-hidden />;
  }

  function compareStrings(a: string, b: string): number {
    return a.localeCompare(b, undefined, { sensitivity: 'base' });
  }

  function updateViewMode(next: 'card' | 'list') {
    setViewMode(next);
    setCookieValue(VIEW_MODE_COOKIE, next, VIEW_MODE_MAX_AGE_SECS);
  }

  const totalPages = Math.max(1, Math.ceil(list.length / pageSize));
  useEffect(() => {
    setPage((p) => Math.max(1, Math.min(totalPages, p)));
  }, [totalPages]);

  const startIndex = (page - 1) * pageSize;
  const endIndexExclusive = startIndex + pageSize;
  const sortedList = sortKey
    ? [...list].sort((a, b) => {
        const dir = sortDir === 'asc' ? 1 : -1;
        if (sortKey === 'name') return dir * compareStrings(a.name ?? '', b.name ?? '');
        if (sortKey === 'type') {
          const ad = getProviderDisplayName(a.provider_type ?? '');
          const bd = getProviderDisplayName(b.provider_type ?? '');
          return dir * compareStrings(ad, bd);
        }
        // created
        const at = new Date(a.created_at).getTime();
        const bt = new Date(b.created_at).getTime();
        const safeAt = Number.isFinite(at) ? at : 0;
        const safeBt = Number.isFinite(bt) ? bt : 0;
        return dir * (safeAt - safeBt);
      })
    : list;

  const pagedList = sortedList.slice(startIndex, endIndexExclusive);

  function load(): Promise<DnsProviderRow[]> {
    setLoading(true);
    setError(null);
    return Promise.all([api.dnsProviders.list(), api.dnsProviders.supported()])
      .then(([rows, sup]) => {
        const safeRows = Array.isArray(rows) ? rows : [];
        setList(safeRows);
        setSupported(Array.isArray(sup) ? sup : []);
        setDbUnavailable(false);
        return safeRows;
      })
      .catch((e) => {
        const msg = e instanceof Error ? e.message : 'Failed to load';
        setError(msg);
        if (msg.includes('503') || msg.includes('database') || msg.includes('not configured')) {
          setDbUnavailable(true);
        }
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
    setValidateDetails(null);
    setShowForm(true);
  }

  function openEdit(row: DnsProviderRow) {
    setEditingId(row.id);
    setFormName(row.name);
    setFormType(row.provider_type);
    setFormCreds(row.credentials && typeof row.credentials === 'object' ? { ...row.credentials } : {});
    setFieldVisibility({});
    setFormError(null);
    setValidateDetails(null);
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

  async function handleValidate() {
    setFormError(null);
    setValidateDetails(null);
    const provider_type = formType.trim();
    if (!provider_type) {
      setFormError('Provider type is required');
      return;
    }
    const credentials = buildCredentials();
    if (selectedProvider?.fields.some((f) => f.required && !formCreds[f.key]?.trim())) {
      setFormError('All required fields must be filled');
      return;
    }
    setValidating(true);
    try {
      const result = await api.dnsProviders.validate(provider_type, credentials);
      setValidateDetails(formatValidateDetails(result.details));
      toast.success('DNS provider validation passed.');
    } catch (e) {
      const msg = e instanceof Error ? e.message : 'Validation failed';
      setFormError(msg);
      toast.error(msg);
    } finally {
      setValidating(false);
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
      .then(({ ok, rows, reason }) => {
        setList(rows);
        if (ok) {
          toast.success('DNS provider removed.');
        } else {
          toast.error(reason ?? 'Failed to delete DNS provider.');
        }
      })
      .catch((e) => toast.error(e instanceof Error ? e.message : 'Failed to delete'))
      .finally(() => setDeletingId(null));
  }

  function getProviderDisplayName(providerType: string): string {
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

  if (dbUnavailable) {
    return (
      <section className={styles.section}>
        <p className={styles.error}>
          DNS providers require the database. Start the proxy with <code>--db ./data/pertisk.db</code>.
        </p>
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
      <div className={styles.header}>
        <div className={styles.headerActions}>
          <div className={styles.viewToggle}>
            <button
              type="button"
              className={viewMode === 'card' ? styles.viewBtnActive : styles.viewBtn}
              onClick={() => updateViewMode('card')}
            >
              <FaIcon className="fas fa-th" aria-hidden /> Cards
            </button>
            <button
              type="button"
              className={viewMode === 'list' ? styles.viewBtnActive : styles.viewBtn}
              onClick={() => updateViewMode('list')}
            >
              <FaIcon className="fas fa-list" aria-hidden /> List
            </button>
          </div>
          <button type="button" className={styles.btnPrimary} onClick={openAdd}>
            <FaIcon className="fas fa-plus" aria-hidden /> Add DNS provider
          </button>
        </div>
      </div>

      {list.length === 0 ? (
        <div className={styles.emptyState}>
          <FaIcon className="fas fa-server" size={48} aria-hidden />
          <h3 className={styles.emptyTitle}>No DNS providers</h3>
          <p className={styles.emptyText}>Add one for DNS-01 challenges (e.g. wildcard certs).</p>
          <button type="button" className={styles.btnPrimary} onClick={openAdd}>
            <FaIcon className="fas fa-plus" aria-hidden /> Add DNS provider
          </button>
        </div>
      ) : viewMode === 'card' ? (
        <div className={styles.cardGrid}>
          {pagedList.map((row) => (
            <div key={row.id} className={styles.providerCard}>
              <div className={styles.providerCardHeader}>
                <h3 className={styles.providerCardName}>
                  <FaIcon className="fas fa-server" aria-hidden />
                  {row.name}
                </h3>
                <span className={styles.providerCardType}>{getProviderDisplayName(row.provider_type)}</span>
              </div>
              <div className={styles.providerCardBody}>
                <div className={styles.providerCardMeta}>
                  <span className={styles.metaLabel}>Created</span>
                  <span className={styles.metaValue}>{formatDateTime(row.created_at)}</span>
                </div>
                <div className={styles.providerCardActions}>
                  <button
                    type="button"
                    className={styles.btnSecondary}
                    onClick={() => loadFullThenEdit(row.id)}
                  >
                    <FaIcon className="fas fa-edit" aria-hidden /> View / Edit
                  </button>
                  <button type="button" className={styles.btnDanger} onClick={() => openDeleteConfirm(row)}>
                    <FaIcon className="fas fa-trash" aria-hidden /> Remove
                  </button>
                </div>
              </div>
            </div>
          ))}
        </div>
      ) : (
        <div className={styles.tableWrap}>
          <table className={styles.table}>
            <thead>
              <tr>
                <th aria-sort={sortKey === 'name' ? (sortDir === 'asc' ? 'ascending' : 'descending') : 'none'}>
                  <button type="button" className={styles.sortBtn} onClick={() => toggleSort('name')}>
                    Name {sortIcon('name')}
                  </button>
                </th>
                <th aria-sort={sortKey === 'type' ? (sortDir === 'asc' ? 'ascending' : 'descending') : 'none'}>
                  <button type="button" className={styles.sortBtn} onClick={() => toggleSort('type')}>
                    Type {sortIcon('type')}
                  </button>
                </th>
                <th aria-sort={sortKey === 'created' ? (sortDir === 'asc' ? 'ascending' : 'descending') : 'none'}>
                  <button type="button" className={styles.sortBtn} onClick={() => toggleSort('created')}>
                    Created {sortIcon('created')}
                  </button>
                </th>
                <th className={styles.actionsCol} />
              </tr>
            </thead>
            <tbody>
              {pagedList.map((row) => (
                <tr key={row.id} className={styles.tableRow}>
                  <td className={styles.name}>
                    <div className={styles.primaryCell}>
                      <div className={styles.providerIdentity}>
                        <span className={styles.providerBadge}>
                          <FaIcon className="fas fa-server" aria-hidden />
                        </span>
                        <span className={styles.nameText}>{row.name}</span>
                      </div>
                    </div>
                  </td>
                  <td>
                    <span className={styles.statusPill}>{getProviderDisplayName(row.provider_type)}</span>
                  </td>
                  <td>
                    <span className={styles.datePrimary}>{formatDateTime(row.created_at)}</span>
                  </td>
                  <td className={styles.actionsCol}>
                    <div className={styles.rowActions}>
                      <button
                        type="button"
                        className={styles.btnSecondary}
                        onClick={() => loadFullThenEdit(row.id)}
                      >
                        View / Edit
                      </button>
                      <button type="button" className={styles.btnDanger} onClick={() => openDeleteConfirm(row)}>
                        Remove
                      </button>
                    </div>
                  </td>
                </tr>
              ))}
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
          >
          <div className={styles.modal} role="dialog" aria-modal="true" aria-labelledby="dns-provider-modal-title">
            <div className={styles.modalHeader}>
              <h2 id="dns-provider-modal-title">
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
                {' '}
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
                {' '}
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
                  {supported.map((p) => (
                    <option key={p.id} value={p.id}>
                      {p.name}
                    </option>
                  ))}
                </select>
              </label>

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
              {validateDetails && (
                <div className={styles.helpText}>
                  {validateDetails.map((line) => (
                    <p key={line} className={styles.helpLine}>{line}</p>
                  ))}
                </div>
              )}
              <div className={styles.modalActions}>
                <button type="button" className={styles.btnSecondary} onClick={() => setShowForm(false)}>
                  Cancel
                </button>
                <button type="button" className={styles.btnSecondary} disabled={validating || saving} onClick={() => void handleValidate()}>
                  {validating ? 'Validating…' : 'Validate credentials'}
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

type CredentialFieldProps = Readonly<{
  field: SupportedDnsProviderField;
  value: string;
  onChange: (v: string) => void;
  visible: boolean;
  onToggleVisibility: () => void;
  inputClassName: string;
  textareaClassName: string;
  labelClassName: string;
}>;

function PasswordField({
  field,
  value,
  visible,
  onChange,
  onToggleVisibility,
  inputClassName,
}: Readonly<{
  field: SupportedDnsProviderField;
  value: string;
  visible: boolean;
  onChange: (v: string) => void;
  onToggleVisibility: () => void;
  inputClassName: string;
}>) {
  const passwordType = visible ? 'text' : 'password';
  const toggleTitle = visible ? 'Hide' : 'Show';
  const toggleAria = visible ? 'Hide password' : 'Show password';
  const eyeClass = visible ? 'fas fa-eye-slash' : 'fas fa-eye';

  return (
    <div className={styles.passwordWrap}>
      <input
        name={`dns-provider-${field.key}`}
        type={passwordType}
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
        title={toggleTitle}
        aria-label={toggleAria}
      >
        <FaIcon className={eyeClass} />
      </button>
    </div>
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
}: CredentialFieldProps) {
  const isPassword = field.type === 'password';
  const isTextarea = field.type === 'textarea';
  const isSensitiveKey = /token|secret|key|password/i.test(field.key);

  let control: JSX.Element;

  if (isTextarea) {
    control = (
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
    );
  } else if (isPassword) {
    control = (
      <PasswordField
        field={field}
        value={value}
        visible={visible}
        onChange={onChange}
        onToggleVisibility={onToggleVisibility}
        inputClassName={inputClassName}
      />
    );
  } else {
    control = (
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
    );
  }

  return (
    <label className={labelClassName}>
      {field.label}
      {field.required && ' *'}
      {control}
    </label>
  );
}
