import FaIcon from '@/components/FaIcon';
import { useEffect, useState, FormEvent, useMemo } from 'react';
import { createPortal } from 'react-dom';
import { Link } from 'react-router-dom';
import { api, type ProxyConfig, type Site, type PathRewrite, type Backend } from '@/api/client';
import { getCookieValue, setCookieValue } from '@/auth';
import { useToast } from '@/context/ToastContext';
import ConfirmDialog from '@/components/ConfirmDialog';
import Pagination from '@/components/Pagination';
import { usePageSize } from '@/utils/usePageSize';
import styles from './Sites.module.css';

const PATH_TYPES = ['Prefix', 'Exact', 'ImplementationSpecific'];
const VIEW_MODE_COOKIE = 'pertisk_sites_view';
const VIEW_MODE_MAX_AGE_SECS = 60 * 60 * 24 * 365;
const EMPTY_SITES: Site[] = [];
const EMPTY_BACKENDS: Backend[] = [];

function normalizeViewMode(value: string | null): 'card' | 'list' {
  return value === 'card' ? 'card' : 'list';
}

function domainUrl(host: string): string {
  const h = host?.trim() || '';
  if (!h || h === '—') return '';
  const base = h.startsWith('*.') ? h.slice(2) : h;
  return 'https://' + base;
}

function routeLabel(route: PathRewrite): string {
  const pt = route.path_type || 'prefix';
  const ptDisp = typeof pt === 'string' ? pt.charAt(0).toUpperCase() + pt.slice(1) : String(pt);
  return `${ptDisp} ${route.path}${route.rewrite != null && route.rewrite !== '' ? ` → ${route.rewrite}` : ''}`;
}

function normalizeUpstream(url: string): string {
  const s = url.trim();
  if (!s) return s;
  if (/^https?:\/\//i.test(s)) return s;
  return 'http://' + s;
}

/** Map UI path type to eProxy API (lowercase). */
function toApiPathType(pt: string): 'prefix' | 'exact' {
  const u = (pt || 'Prefix').toLowerCase();
  if (u === 'exact') return 'exact';
  return 'prefix';
}

/** Display path type in form (Title Case). */
function toFormPathType(pt: string | undefined): string {
  if (!pt) return 'Prefix';
  const s = String(pt).toLowerCase();
  if (s === 'exact') return 'Exact';
  if (s === 'prefix') return 'Prefix';
  return 'ImplementationSpecific';
}

type DisplaySiteItem = {
  key: string;
  site: Site;
  index: number;
};

type SslMode = 'none' | 'from_list';

export default function Sites() {
  const [config, setConfig] = useState<ProxyConfig | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);
  const [showForm, setShowForm] = useState(false);
  const [editingIndex, setEditingIndex] = useState<number | null>(null);
  const [formHost, setFormHost] = useState('');
  const [formUpstream, setFormUpstream] = useState('');
  const [formRoutes, setFormRoutes] = useState<{ path: string; path_type: string; rewrite: string }[]>([
    { path: '/', path_type: 'Prefix', rewrite: '/' },
  ]);
  const [formSslMode, setFormSslMode] = useState<SslMode>('none');
  const [formCertName, setFormCertName] = useState('');
  const [formDnsProviderName, setFormDnsProviderName] = useState('');
  const [formError, setFormError] = useState<string | null>(null);
  const [viewMode, setViewMode] = useState<'card' | 'list'>(() =>
    normalizeViewMode(getCookieValue(VIEW_MODE_COOKIE)),
  );
  const pageSize = usePageSize();
  const [page, setPage] = useState(1);
  type SortKey = 'domain' | 'upstream' | 'routes' | 'ssl';
  const [sortKey, setSortKey] = useState<SortKey | null>(null);
  const [sortDir, setSortDir] = useState<'asc' | 'desc'>('asc');
  const [deleteConfirmIndex, setDeleteConfirmIndex] = useState<number | null>(null);
  const toast = useToast();

  const sites = config?.sites ?? EMPTY_SITES;
  const backends = config?.backends ?? EMPTY_BACKENDS;
  const certNames = config?.certificates ?? [];
  const dnsNames = config?.dns_providers ?? [];

  const displaySiteItems: DisplaySiteItem[] = useMemo(
    () =>
      sites.map((site, index) => ({
        key: `${site.host}-${index}`,
        site,
        index,
      })),
    [sites],
  );

  const totalPages = Math.max(1, Math.ceil(displaySiteItems.length / pageSize));
  useEffect(() => {
    setPage((p) => Math.max(1, Math.min(totalPages, p)));
  }, [totalPages]);

  const startIndex = (page - 1) * pageSize;
  const endIndexExclusive = startIndex + pageSize;

  function upstreamForSite(site: Site): string {
    const be = backends.find((b) => b.name === site.backend);
    return be?.upstreams?.[0]?.addr ?? site.backend;
  }

  function sslLabelForSite(site: Site): string {
    if (site.certificate?.trim()) return site.certificate.trim();
    return '—';
  }

  function compareStrings(a: string, b: string): number {
    return a.localeCompare(b, undefined, { sensitivity: 'base' });
  }

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

  const sortedSiteItems = sortKey
    ? [...displaySiteItems].sort((a, b) => {
        const dir = sortDir === 'asc' ? 1 : -1;
        if (sortKey === 'domain') return dir * compareStrings(a.site.host ?? '', b.site.host ?? '');
        if (sortKey === 'upstream') return dir * compareStrings(upstreamForSite(a.site), upstreamForSite(b.site));
        if (sortKey === 'routes') return dir * ((a.site.routes?.length ?? 0) - (b.site.routes?.length ?? 0));
        return dir * compareStrings(sslLabelForSite(a.site), sslLabelForSite(b.site));
      })
    : displaySiteItems;

  const pagedSiteItems = sortedSiteItems.slice(startIndex, endIndexExclusive);

  function updateViewMode(next: 'card' | 'list') {
    setViewMode(next);
    setCookieValue(VIEW_MODE_COOKIE, next, VIEW_MODE_MAX_AGE_SECS);
  }

  function load() {
    api
      .config()
      .then(setConfig)
      .catch((e) => setError(e instanceof Error ? e.message : 'Failed to load config'));
  }

  useEffect(() => {
    load();
  }, []);

  useEffect(() => {
    if (!showForm) return;
    const prevOverflow = document.body.style.overflow;
    document.body.style.overflow = 'hidden';
    return () => {
      document.body.style.overflow = prevOverflow;
    };
  }, [showForm]);

  function addRoute() {
    setFormRoutes((r) => [...r, { path: '', path_type: 'Prefix', rewrite: '' }]);
  }

  function removeRoute(i: number) {
    setFormRoutes((r) => r.filter((_, idx) => idx !== i));
  }

  function updateRoute(i: number, field: 'path' | 'path_type' | 'rewrite', value: string) {
    setFormRoutes((r) => {
      const next = [...r];
      const cur = { ...next[i] };
      if (field === 'path') cur.path = value;
      else if (field === 'path_type') cur.path_type = value;
      else cur.rewrite = value;
      next[i] = cur;
      return next;
    });
  }

  function openAdd() {
    setEditingIndex(null);
    setFormHost('');
    setFormUpstream('');
    setFormRoutes([{ path: '/', path_type: 'Prefix', rewrite: '/' }]);
    setFormSslMode('none');
    setFormCertName('');
    setFormDnsProviderName('');
    setFormError(null);
    setShowForm(true);
  }

  function openEdit(index: number) {
    const site = sites[index];
    if (!site) return;
    setEditingIndex(index);
    setFormHost(site.host);
    const be = backends.find((b) => b.name === site.backend);
    setFormUpstream(be?.upstreams?.[0]?.addr ?? '');
    setFormRoutes(
      site.routes?.length
        ? site.routes.map((r) => ({
            path: r.path ?? '/',
            path_type: toFormPathType(r.path_type),
            rewrite: r.rewrite ?? '',
          }))
        : [{ path: '/', path_type: 'Prefix', rewrite: '/' }],
    );
    setFormSslMode(site.certificate?.trim() ? 'from_list' : 'none');
    setFormCertName(site.certificate?.trim() ?? '');
    setFormDnsProviderName(site.dns_provider?.trim() ?? '');
    setFormError(null);
    setShowForm(true);
  }

  function openDuplicate(index: number) {
    const site = sites[index];
    if (!site) return;
    setEditingIndex(null);
    setFormHost(`${site.host}-copy`);
    const be = backends.find((b) => b.name === site.backend);
    setFormUpstream(be?.upstreams?.[0]?.addr ?? '');
    setFormRoutes(
      site.routes?.length
        ? site.routes.map((r) => ({
            path: r.path ?? '/',
            path_type: toFormPathType(r.path_type),
            rewrite: r.rewrite ?? '',
          }))
        : [{ path: '/', path_type: 'Prefix', rewrite: '/' }],
    );
    setFormSslMode('none');
    setFormCertName('');
    setFormDnsProviderName(site.dns_provider?.trim() ?? '');
    setFormError(null);
    setShowForm(true);
  }

  function buildRoutes(): PathRewrite[] {
    return formRoutes
      .map((r) => ({
        path: r.path.trim(),
        path_type: toApiPathType(r.path_type),
        rewrite: r.rewrite?.trim() || undefined,
      }))
      .filter((r) => r.path);
  }

  async function handleSubmit(e: FormEvent) {
    e.preventDefault();
    setFormError(null);
    const host = formHost.trim();
    if (!host) {
      setFormError('Domain is required');
      return;
    }
    const rawUpstream = formUpstream.trim();
    if (!rawUpstream) {
      setFormError('Upstream URL is required');
      return;
    }
    const routes = buildRoutes();
    if (routes.length === 0) {
      setFormError('At least one route with a path is required');
      return;
    }
    if (!config) return;

    if (formSslMode === 'from_list' && !formCertName.trim()) {
      setFormError('Select or enter a certificate name when using “Existing certificate label”.');
      return;
    }

    const addr = normalizeUpstream(rawUpstream);
    let newBackends = [...backends];
    const baseName =
      'inline-' +
        host
          .replace(/[^a-z0-9.-]/gi, '-')
          .replace(/-+/g, '-')
          .replace(/^-|-$/g, '') || 'site';
    let backendName: string;
    if (editingIndex !== null) {
      const existingSite = sites[editingIndex];
      const existingBackend = existingSite && newBackends.find((b) => b.name === existingSite.backend);
      if (existingBackend?.upstreams?.length === 1) {
        newBackends = newBackends.map((b) =>
          b.name === existingSite!.backend
            ? {
                ...b,
                upstreams: [{ ...b.upstreams[0], addr }],
                algorithm: b.algorithm ?? 'round_robin',
              }
            : b,
        );
        backendName = existingSite!.backend;
      } else {
        backendName = baseName;
        let n = 1;
        while (newBackends.some((b) => b.name === backendName)) backendName = `${baseName}-${n++}`;
        newBackends = [
          ...newBackends,
          {
            name: backendName,
            upstreams: [{ addr, weight: 1 }],
            algorithm: 'round_robin',
            health_interval_secs: 30,
          },
        ];
      }
    } else {
      backendName = baseName;
      let n = 1;
      while (newBackends.some((b) => b.name === backendName)) backendName = `${baseName}-${n++}`;
      newBackends = [
        ...newBackends,
        {
          name: backendName,
          upstreams: [{ addr, weight: 1 }],
          algorithm: 'round_robin',
          health_interval_secs: 30,
        },
      ];
    }

    const certificate = formSslMode === 'from_list' ? formCertName.trim() || null : null;
    const dns_provider = formDnsProviderName.trim() || null;

    const newSite: Site = {
      host,
      backend: backendName,
      routes,
      certificate,
      dns_provider,
    };

    const newSites =
      editingIndex !== null ? sites.map((s, i) => (i === editingIndex ? newSite : s)) : [...sites, newSite];

    setSaving(true);
    try {
      await api.putConfig({
        ...config,
        backends: newBackends,
        sites: newSites,
      });
      setConfig({ ...config, backends: newBackends, sites: newSites });
      setShowForm(false);
      setEditingIndex(null);
      toast.success(editingIndex !== null ? 'Site updated.' : 'Site added.');
    } catch (err) {
      const msg = err instanceof Error ? err.message : 'Failed to save';
      setFormError(msg);
      toast.error(msg);
    } finally {
      setSaving(false);
    }
  }

  async function removeSite(index: number) {
    if (!config) return;
    const site = sites[index];
    if (!site) return;
    setDeleteConfirmIndex(null);
    setSaving(true);
    try {
      await api.deleteSite(site.host);
      const newSites = sites.filter((_, i) => i !== index);
      setConfig({ ...config, sites: newSites });
      toast.success('Site removed.');
      await load();
    } catch (err) {
      toast.error(err instanceof Error ? err.message : 'Failed to remove site');
    } finally {
      setSaving(false);
    }
  }

  const isEditing = editingIndex !== null;

  if (error) {
    return (
      <section className={styles.section}>
        <p className={styles.error}>{error}</p>
        <button type="button" className={styles.btnSecondary} onClick={() => { setError(null); load(); }}>
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
          <button type="button" className={styles.btnPrimary} onClick={openAdd} disabled={saving}>
            <FaIcon className="fas fa-plus" aria-hidden /> Add Site
          </button>
        </div>
      </div>

      {config && (
        <>
          {sites.length === 0 ? (
            <div className={styles.emptyState}>
              <FaIcon className="fas fa-globe" size={48} aria-hidden />
              <h3 className={styles.emptyTitle}>No sites configured</h3>
              <p className={styles.emptyText}>Get started by adding your first reverse proxy site</p>
              <button type="button" className={styles.btnPrimary} onClick={openAdd} disabled={saving}>
                <FaIcon className="fas fa-plus" aria-hidden /> Add Your First Site
              </button>
            </div>
          ) : viewMode === 'card' ? (
            <div className={styles.cardGrid}>
              {pagedSiteItems.map((item) => {
                const { site, index: i } = item;
                const up = upstreamForSite(site);
                const routes = site.routes ?? [];
                const ssl = sslLabelForSite(site);
                return (
                  <div key={item.key} className={styles.siteCard}>
                    <div className={styles.siteCardHeader}>
                      <h3 className={styles.siteCardDomain}>
                        <FaIcon className="fas fa-globe" aria-hidden />
                        <Link to={`/sites/${encodeURIComponent(site.host)}`} className={styles.hostText}>
                          {site.host}
                        </Link>
                        {domainUrl(site.host) && (
                          <a
                            href={domainUrl(site.host)}
                            target="_blank"
                            rel="noopener noreferrer"
                            className={styles.domainLinkIcon}
                            title="Open in new tab"
                            aria-label={`Open ${site.host} in new tab`}
                          >
                            <FaIcon className="fas fa-external-link-alt" aria-hidden />
                          </a>
                        )}
                      </h3>
                    </div>
                    <div className={styles.siteCardBody}>
                      <div className={styles.siteCardMeta}>
                        <span className={styles.metaLabel}>Upstream</span>
                        <span className={styles.metaValue}>{up || '—'}</span>
                      </div>
                      <div className={styles.siteCardMeta}>
                        <span className={styles.metaLabel}>Backend</span>
                        <span className={styles.metaValue}>{site.backend}</span>
                      </div>
                      <div className={styles.siteCardMeta}>
                        <span className={styles.metaLabel}>Routes</span>
                        <div className={styles.routes}>
                          {routes.map((r, j) => (
                            <span key={`${routeLabel(r)}-${j}`} className={styles.routeChip}>
                              {routeLabel(r)}
                            </span>
                          ))}
                        </div>
                      </div>
                      <div className={styles.siteCardMeta}>
                        <span className={styles.metaLabel}>Certificate</span>
                        <span className={styles.metaValue}>{ssl}</span>
                      </div>
                      {site.dns_provider && (
                        <div className={styles.siteCardMeta}>
                          <span className={styles.metaLabel}>DNS provider</span>
                          <span className={styles.metaValue}>{site.dns_provider}</span>
                        </div>
                      )}
                      <div className={styles.siteCardActions}>
                        <button
                          type="button"
                          className={styles.btnEdit}
                          onClick={() => openEdit(i)}
                          disabled={saving}
                          title="Edit"
                        >
                          <FaIcon className="fas fa-edit" aria-hidden /> Edit
                        </button>
                        <button
                          type="button"
                          className={styles.btnDuplicate}
                          onClick={() => openDuplicate(i)}
                          disabled={saving}
                          title="Duplicate"
                        >
                          <FaIcon className="fas fa-copy" aria-hidden /> Duplicate
                        </button>
                        <button
                          type="button"
                          className={styles.btnDanger}
                          onClick={() => setDeleteConfirmIndex(i)}
                          disabled={saving}
                          title="Delete"
                        >
                          <FaIcon className="fas fa-trash" aria-hidden /> Delete
                        </button>
                      </div>
                    </div>
                  </div>
                );
              })}
            </div>
          ) : (
            <div className={styles.tableWrap}>
              <table className={styles.table}>
                <thead>
                  <tr>
                    <th aria-sort={sortKey === 'domain' ? (sortDir === 'asc' ? 'ascending' : 'descending') : 'none'}>
                      <button type="button" className={styles.sortBtn} onClick={() => toggleSort('domain')}>
                        Domain {sortIcon('domain')}
                      </button>
                    </th>
                    <th aria-sort={sortKey === 'upstream' ? (sortDir === 'asc' ? 'ascending' : 'descending') : 'none'}>
                      <button type="button" className={styles.sortBtn} onClick={() => toggleSort('upstream')}>
                        Upstream {sortIcon('upstream')}
                      </button>
                    </th>
                    <th aria-sort={sortKey === 'routes' ? (sortDir === 'asc' ? 'ascending' : 'descending') : 'none'}>
                      <button type="button" className={styles.sortBtn} onClick={() => toggleSort('routes')}>
                        Routes {sortIcon('routes')}
                      </button>
                    </th>
                    <th aria-sort={sortKey === 'ssl' ? (sortDir === 'asc' ? 'ascending' : 'descending') : 'none'}>
                      <button type="button" className={styles.sortBtn} onClick={() => toggleSort('ssl')}>
                        Certificate {sortIcon('ssl')}
                      </button>
                    </th>
                    <th className={styles.actionsCol}>Actions</th>
                  </tr>
                </thead>
                <tbody>
                  {pagedSiteItems.map((item) => {
                    const { site, index: i } = item;
                    const up = upstreamForSite(site);
                    const routes = site.routes ?? [];
                    const ssl = sslLabelForSite(site);
                    return (
                      <tr key={item.key} className={styles.tableRow}>
                        <td className={styles.host}>
                          <div className={styles.primaryCell}>
                            <div className={styles.hostInner}>
                              <span className={styles.hostBadge}>
                                <FaIcon className="fas fa-globe" aria-hidden />
                              </span>
                              <span className={styles.hostTextGroup}>
                                <Link to={`/sites/${encodeURIComponent(site.host)}`} className={styles.hostText}>
                                  {site.host}
                                </Link>
                                <span className={styles.cellSubtle}>Cert {ssl}</span>
                              </span>
                            </div>
                            {domainUrl(site.host) && (
                              <a
                                href={domainUrl(site.host)}
                                target="_blank"
                                rel="noopener noreferrer"
                                className={styles.domainLinkIcon}
                                title="Open in new tab"
                                aria-label={`Open ${site.host} in new tab`}
                              >
                                <FaIcon className="fas fa-external-link-alt" aria-hidden />
                              </a>
                            )}
                          </div>
                        </td>
                        <td className={styles.upstream}>
                          <div className={styles.cellStack}>
                            <span className={styles.monoPrimary}>{up || '—'}</span>
                            <span className={styles.cellSubtle}>{site.backend}</span>
                          </div>
                        </td>
                        <td>
                          <div className={styles.cellStack}>
                            <div className={styles.routeListModern}>
                              {routes.slice(0, 3).map((route, routeIndex) => (
                                <span key={`${routeLabel(route)}-${routeIndex}`} className={styles.routeChip}>
                                  {routeLabel(route)}
                                </span>
                              ))}
                              {routes.length > 3 && <span className={styles.routeMore}>+{routes.length - 3}</span>}
                            </div>
                          </div>
                        </td>
                        <td className={styles.sslCol}>
                          <span className={styles.statusPill}>{ssl}</span>
                        </td>
                        <td>
                          <div className={styles.rowActions}>
                            <button type="button" className={styles.btnEdit} onClick={() => openEdit(i)} disabled={saving}>
                              <FaIcon className="fas fa-edit" aria-hidden /> Edit
                            </button>
                            <button
                              type="button"
                              className={styles.btnDuplicate}
                              onClick={() => openDuplicate(i)}
                              disabled={saving}
                            >
                              <FaIcon className="fas fa-copy" aria-hidden /> Duplicate
                            </button>
                            <button
                              type="button"
                              className={styles.btnDanger}
                              onClick={() => setDeleteConfirmIndex(i)}
                              disabled={saving}
                            >
                              <FaIcon className="fas fa-trash" aria-hidden /> Delete
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

          {sites.length > 0 && (
            <Pagination
              totalItems={displaySiteItems.length}
              pageSize={pageSize}
              page={page}
              onPageChange={setPage}
              ariaLabel="Sites pagination"
            />
          )}
        </>
      )}

      {showForm &&
        createPortal(
          <div
            className={styles.modalBackdrop}
            role="presentation"
            onClick={(e) => {
              if (e.target === e.currentTarget) setShowForm(false);
            }}
          >
            <div className={`${styles.modal} ${styles.modalSite}`} role="dialog" aria-modal="true">
            <div className={styles.modalHeader}>
              <h2>
                <FaIcon className={isEditing ? 'fas fa-pen-to-square' : 'fas fa-plus'} aria-hidden />{' '}
                {isEditing ? 'Edit Site' : 'Add Site'}
              </h2>
              <button type="button" className={styles.modalClose} onClick={() => setShowForm(false)} aria-label="Close">
                <FaIcon className="fas fa-times" aria-hidden />
              </button>
            </div>
            <form onSubmit={handleSubmit} className={styles.modalForm}>
              <div className={styles.formSection}>
                <h3 className={styles.sectionTitle}>Basics</h3>
                <div className={styles.formGrid}>
                  <label className={styles.label}>
                    Domain
                    <input
                      type="text"
                      value={formHost}
                      onChange={(e) => setFormHost(e.target.value)}
                      placeholder="example.com"
                      className={styles.input}
                      required
                    />
                  </label>
                  <label className={styles.label}>
                    Upstream
                    <input
                      type="text"
                      value={formUpstream}
                      onChange={(e) => setFormUpstream(e.target.value)}
                      placeholder="http://localhost:8080 or 127.0.0.1:3000"
                      className={styles.input}
                      required
                    />
                  </label>
                </div>
                <p className={styles.hint}>
                  <FaIcon className="fas fa-info-circle" aria-hidden /> A backend entry is created or updated
                  automatically from this upstream URL.
                </p>
              </div>

              <div className={styles.formSection}>
                <h3 className={styles.sectionTitle}>
                  <FaIcon className={`fas fa-lock ${styles.sectionIcon}`} aria-hidden />
                  TLS labels
                </h3>
                <p className={styles.hint}>
                  eProxy uses certificate and DNS provider <strong>names</strong> from your config (for your own
                  tooling). Automatic Let&apos;s Encrypt is not wired here.
                </p>
                <div className={styles.sslChoices}>
                  <label className={formSslMode === 'none' ? styles.sslChoiceActive : styles.sslChoice}>
                    <input
                      type="radio"
                      name="sslMode"
                      checked={formSslMode === 'none'}
                      onChange={() => setFormSslMode('none')}
                      className={styles.radioInput}
                    />
                    <span className={styles.sslChoiceIcon}>
                      <FaIcon className="fas fa-lock-open" aria-hidden />
                    </span>
                    <span>
                      <span className={styles.sslChoiceTitle}>None</span>
                      <span className={styles.sslChoiceText}>No certificate label on this site</span>
                    </span>
                  </label>
                  <label className={formSslMode === 'from_list' ? styles.sslChoiceActive : styles.sslChoice}>
                    <input
                      type="radio"
                      name="sslMode"
                      checked={formSslMode === 'from_list'}
                      onChange={() => setFormSslMode('from_list')}
                      className={styles.radioInput}
                    />
                    <span className={styles.sslChoiceIcon}>
                      <FaIcon className="fas fa-certificate" aria-hidden />
                    </span>
                    <span>
                      <span className={styles.sslChoiceTitle}>Certificate label</span>
                      <span className={styles.sslChoiceText}>Match a name from Certificates</span>
                    </span>
                  </label>
                </div>
                {formSslMode === 'from_list' && (
                  <label className={styles.label}>
                    Certificate name
                    <input
                      type="text"
                      value={formCertName}
                      onChange={(e) => setFormCertName(e.target.value)}
                      list="sites-cert-datalist"
                      placeholder="Pick or type a certificate label"
                      className={styles.input}
                    />
                    <datalist id="sites-cert-datalist">
                      {certNames.map((c) => (
                        <option key={c} value={c} />
                      ))}
                    </datalist>
                  </label>
                )}
                <label className={styles.label}>
                  DNS provider label (optional)
                  <input
                    type="text"
                    value={formDnsProviderName}
                    onChange={(e) => setFormDnsProviderName(e.target.value)}
                    list="sites-dns-datalist"
                    placeholder="Pick or type a DNS provider label"
                    className={styles.input}
                  />
                  <datalist id="sites-dns-datalist">
                    {dnsNames.map((d) => (
                      <option key={d} value={d} />
                    ))}
                  </datalist>
                </label>
              </div>

              <div className={styles.formSection}>
                <div className={styles.routesHeader}>
                  <h3 className={styles.sectionTitle}>
                    <FaIcon className={`fas fa-route ${styles.sectionIcon}`} aria-hidden />
                    Routes
                  </h3>
                  <button type="button" className={styles.btnSecondary} onClick={addRoute}>
                    <FaIcon className="fas fa-plus" aria-hidden /> Add route
                  </button>
                </div>
                {formRoutes.map((r, i) => (
                  <div key={i} className={styles.routeRow}>
                    <div className={styles.selectWrapSm}>
                      <FaIcon className={`fas fa-code-branch ${styles.selectLeadIconSm}`} aria-hidden />
                      <select
                        value={r.path_type ?? 'Prefix'}
                        onChange={(e) => updateRoute(i, 'path_type', e.target.value)}
                        className={`${styles.selectSm} ${styles.selectSmWithLead}`}
                      >
                        {PATH_TYPES.map((t) => (
                          <option key={t} value={t}>
                            {t}
                          </option>
                        ))}
                      </select>
                      <FaIcon className={`fas fa-chevron-down ${styles.selectIcon}`} aria-hidden />
                    </div>
                    <input
                      type="text"
                      value={r.path}
                      onChange={(e) => updateRoute(i, 'path', e.target.value)}
                      placeholder="/api"
                      className={styles.inputFlex}
                    />
                    <input
                      type="text"
                      value={r.rewrite ?? ''}
                      onChange={(e) => updateRoute(i, 'rewrite', e.target.value)}
                      placeholder="rewrite (optional)"
                      className={styles.inputFlex}
                    />
                    <button
                      type="button"
                      className={styles.btnIconDanger}
                      onClick={() => removeRoute(i)}
                      title="Remove route"
                    >
                      <FaIcon className="fas fa-times" aria-hidden />
                    </button>
                  </div>
                ))}
              </div>

              {formError && <p className={styles.formError}>{formError}</p>}

              <div className={styles.modalActions}>
                <button type="button" className={styles.btnSecondary} onClick={() => setShowForm(false)}>
                  Cancel
                </button>
                <button type="submit" className={styles.btnPrimary} disabled={saving}>
                  {saving ? (
                    <>
                      <FaIcon className="fas fa-spinner fa-spin" aria-hidden /> Saving…
                    </>
                  ) : isEditing ? (
                    'Save changes'
                  ) : (
                    'Add site'
                  )}
                </button>
              </div>
            </form>
          </div>
        </div>,
          document.body,
        )}

      <ConfirmDialog
        open={deleteConfirmIndex !== null}
        title="Delete site"
        message={
          deleteConfirmIndex !== null && sites[deleteConfirmIndex]
            ? `Remove ${sites[deleteConfirmIndex].host} from configuration?`
            : ''
        }
        primaryLabel="Delete"
        variant="danger"
        onCancel={() => setDeleteConfirmIndex(null)}
        onConfirm={() => {
          if (deleteConfirmIndex !== null) void removeSite(deleteConfirmIndex);
        }}
      />
    </section>
  );
}
