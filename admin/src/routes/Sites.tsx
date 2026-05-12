import FaIcon from '@/components/FaIcon';
import { useEffect, useState, FormEvent, useMemo, useCallback } from 'react';
import { createPortal } from 'react-dom';
import {
  api,
  type ProxyConfig,
  type Site,
  type PathRewrite,
  type Backend,
  type CertificateRow,
  type ManagementInfo,
  normalizeDnsProviders,
} from '@/api/client';
import { getCookieValue, setCookieValue } from '@/auth';
import { useToast } from '@/context/ToastContext';
import { useSslJobs, formatAcmeSslPhase } from '@/context/SslJobContext';
import ConfirmDialog from '@/components/ConfirmDialog';
import Pagination from '@/components/Pagination';
import { usePageSize } from '@/utils/usePageSize';
import styles from './Sites.module.css';

const PATH_TYPES = ['Prefix', 'Exact', 'ImplementationSpecific'];
const VIEW_MODE_COOKIE = 'pertisk_sites_view';
const VIEW_MODE_MAX_AGE_SECS = 60 * 60 * 24 * 365;
const EMPTY_SITES: Site[] = [];
const EMPTY_BACKENDS: Backend[] = [];

type SitesCache = {
  config: ProxyConfig | null;
  issuedTlsCerts: CertificateRow[];
};

let sitesCache: SitesCache | null = null;

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

function wildcardDomainFromHost(host: string): string {
  const raw = host.trim().toLowerCase();
  const noScheme = raw.replace(/^[a-z]+:\/\//, '');
  const noPath = noScheme.split('/')[0] ?? '';
  const noPort = noPath.split(':')[0] ?? '';
  const h = noPort.replace(/^\*\./, '').replace(/\.$/, '');
  if (!h) return '*.domain';
  const parts = h.split('.').filter(Boolean);
  if (parts.length >= 3) {
    return `*.${parts.slice(1).join('.')}`;
  }
  return `*.${h}`;
}

function wildcardBaseFromHost(host: string): string {
  const wildcard = wildcardDomainFromHost(host);
  return wildcard.startsWith('*.') ? wildcard.slice(2) : wildcard;
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

/** Same header-line format as pertisk-rproxy Settings / Sites. */
function formatHeaderLines(headers: Record<string, string> | null | undefined): string {
  if (!headers) return '';
  return Object.entries(headers)
    .map(([k, v]) => `${k}: ${v}`)
    .join('\n');
}

function parseHeaderLines(input: string): { headers: Record<string, string>; error?: string } {
  const headers: Record<string, string> = {};
  const lines = input.split(/\r?\n/);
  for (const line of lines) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    const idx = trimmed.indexOf(':');
    if (idx <= 0) {
      return { headers, error: `Invalid header line: "${line}"` };
    }
    const name = trimmed.slice(0, idx).trim();
    const value = trimmed.slice(idx + 1).trim();
    headers[name] = value;
  }
  return { headers };
}

type DisplaySiteItem = {
  key: string;
  site: Site;
  index: number;
};

type SslMode = 'none' | 'existing_cert' | 'auto_ssl';
type ChallengeType = 'http-01' | 'dns-01';

export default function Sites() {
  const { jobsByHost, lastPush } = useSslJobs();
  const [config, setConfig] = useState<ProxyConfig | null>(() => sitesCache?.config ?? null);
  const [loading, setLoading] = useState(() => sitesCache == null);
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
  const [formContactEmail, setFormContactEmail] = useState('');
  const [formChallengeType, setFormChallengeType] = useState<ChallengeType>('http-01');
  const [formWildcard, setFormWildcard] = useState(false);
  const [formAdvertiseHttp3, setFormAdvertiseHttp3] = useState(true);
  const [formSecurityMode, setFormSecurityMode] = useState<'inherit' | 'override'>('inherit');
  const [formSecurityHeadersText, setFormSecurityHeadersText] = useState('');
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
  const [issuedTlsCerts, setIssuedTlsCerts] = useState<CertificateRow[]>(() => sitesCache?.issuedTlsCerts ?? []);
  const [managementInfo, setManagementInfo] = useState<ManagementInfo | null>(null);
  const toast = useToast();
  const wildcardLabel = wildcardDomainFromHost(formHost);

  const altSvcSupport = useMemo(() => {
    const caps = managementInfo?.runtime_capabilities;
    const httpsPort = config?.https_port;
    const hasHttps = typeof httpsPort === 'number' && httpsPort > 0;
    const h3Listeners = Boolean(caps?.h3_api_gateway_config) || Boolean(caps?.proxy_http3_udp);
    return { hasHttps, httpsPort: hasHttps ? httpsPort : null, h3Listeners };
  }, [config?.https_port, managementInfo?.runtime_capabilities]);

  const sites = config?.sites ?? EMPTY_SITES;
  const backends = config?.backends ?? EMPTY_BACKENDS;
  const dnsNames = useMemo(
    () => normalizeDnsProviders(config?.dns_providers).map((e) => e.name).filter((n) => n.length > 0),
    [config?.dns_providers],
  );

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
    const v = site.certificate?.trim();
    if (!v) return '—';
    const row = issuedTlsCerts.find((r) => r.id === v);
    if (row?.hosts?.length) return row.hosts.join(', ');
    return v;
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

  const load = useCallback(async (opts?: { silent?: boolean }) => {
    const silent = opts?.silent === true;
    if (!silent) {
      setLoading(true);
    }
    setError(null);
    try {
      const [nextConfig, certList, mgmt] = await Promise.all([
        api.config(),
        api.certificates.list().catch(() => [] as CertificateRow[]),
        api.management().catch(() => null),
      ]);
      const certs = Array.isArray(certList) ? certList : [];
      setConfig(nextConfig);
      setIssuedTlsCerts(certs);
      setManagementInfo(mgmt);
      sitesCache = {
        config: nextConfig,
        issuedTlsCerts: certs,
      };
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Failed to load config');
      if (sitesCache == null) {
        setConfig(null);
        setIssuedTlsCerts([]);
      }
    } finally {
      if (!silent) {
        setLoading(false);
      }
    }
  }, []);

  useEffect(() => {
    load({ silent: sitesCache != null });
  }, [load]);

  useEffect(() => {
    if (!lastPush) return;
    if (String(lastPush.phase ?? '') !== 'complete') return;
    const timer = window.setTimeout(() => {
      void load({ silent: true });
    }, 1000);
    return () => window.clearTimeout(timer);
  }, [lastPush, load]);

  useEffect(() => {
    if (!showForm) return;
    const root = document.documentElement;
    root.classList.add('eproxy-scroll-lock');
    return () => {
      root.classList.remove('eproxy-scroll-lock');
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
    setFormContactEmail('');
    setFormChallengeType('http-01');
    setFormWildcard(false);
    setFormAdvertiseHttp3(true);
    setFormSecurityMode('inherit');
    setFormSecurityHeadersText('');
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
    const certRef = site.certificate?.trim() ?? '';
    const hasAutoSslSignals =
      Boolean(site.dns_provider?.trim()) ||
      site.challenge_type === 'dns-01' ||
      certRef.startsWith('acme/');
    setFormSslMode(hasAutoSslSignals ? 'auto_ssl' : certRef ? 'existing_cert' : 'none');
    setFormCertName(site.certificate?.trim() ?? '');
    setFormDnsProviderName(site.dns_provider?.trim() ?? '');
    setFormContactEmail(site.acme_contact_email?.trim() ?? '');
    setFormChallengeType(site.challenge_type === 'dns-01' ? 'dns-01' : 'http-01');
    setFormWildcard(Boolean(site.wildcard));
    setFormAdvertiseHttp3(site.advertise_http3 !== false);
    setFormSecurityMode(site.security_headers != null ? 'override' : 'inherit');
    setFormSecurityHeadersText(formatHeaderLines(site.security_headers ?? undefined));
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
    setFormContactEmail('');
    setFormChallengeType('http-01');
    setFormWildcard(false);
    setFormAdvertiseHttp3(true);
    setFormSecurityMode(site.security_headers != null ? 'override' : 'inherit');
    setFormSecurityHeadersText(formatHeaderLines(site.security_headers ?? undefined));
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

    if (formSslMode === 'existing_cert' && !formCertName.trim()) {
      setFormError('Choose a TLS certificate id when using “Certificate label” (see Certificates page).');
      return;
    }
    if (formSslMode === 'auto_ssl' && !formDnsProviderName.trim()) {
      setFormError('Choose a DNS provider for Auto Generate SSL.');
      return;
    }
    if (formSslMode === 'auto_ssl' && !formContactEmail.trim()) {
      setFormError('Contact email is required for Auto Generate SSL.');
      return;
    }
    if (formSslMode === 'auto_ssl' && !formContactEmail.includes('@')) {
      setFormError('Contact email is invalid.');
      return;
    }
    if (formSslMode === 'auto_ssl' && formWildcard && formChallengeType !== 'dns-01') {
      setFormError('Wildcard certificate requires DNS-01 challenge.');
      return;
    }
    let securityHeaders: Record<string, string> | undefined;
    if (formSecurityMode === 'override') {
      const parsed = parseHeaderLines(formSecurityHeadersText);
      if (parsed.error) {
        setFormError(parsed.error);
        return;
      }
      securityHeaders = parsed.headers;
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

    const certificate = formSslMode === 'existing_cert' ? formCertName.trim() || null : null;
    const dns_provider = formSslMode === 'auto_ssl' ? formDnsProviderName.trim() || null : null;
    const challenge_type = formSslMode === 'auto_ssl' ? formChallengeType : null;
    const wildcard = formSslMode === 'auto_ssl' ? formWildcard : false;
    const acme_wildcard_base =
      formSslMode === 'auto_ssl' && formWildcard ? wildcardBaseFromHost(host) : null;
    const acme_contact_email = formSslMode === 'auto_ssl' ? formContactEmail.trim() || null : null;

    const newSite: Site = {
      host,
      backend: backendName,
      routes,
      certificate,
      dns_provider,
      challenge_type,
      wildcard,
      acme_wildcard_base,
      advertise_http3: formAdvertiseHttp3,
      acme_contact_email,
      ...(formSecurityMode === 'override' ? { security_headers: securityHeaders ?? {} } : {}),
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
      {loading && !config ? <div className="spinner" /> : null}
      <div className="page-actions">
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
                        <span className={styles.hostText}>{site.host}</span>
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
                        <div className={styles.certMetaStack}>
                          <span>{ssl}</span>
                          {jobsByHost[site.host] ? (
                            <span
                              className={
                                jobsByHost[site.host].phase === 'error'
                                  ? styles.sslAcmeLiveErr
                                  : styles.sslAcmeLive
                              }
                              title={jobsByHost[site.host].message}
                              role="status"
                            >
                              <FaIcon className="fas fa-spinner" aria-hidden />{' '}
                              {formatAcmeSslPhase(jobsByHost[site.host].phase)}
                            </span>
                          ) : null}
                        </div>
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
                    const sslLive = jobsByHost[site.host];
                    return (
                      <tr key={item.key} className={styles.tableRow}>
                        <td className={styles.host}>
                          <div className={styles.primaryCell}>
                            <div className={styles.hostInner}>
                              <span className={styles.hostBadge}>
                                <FaIcon className="fas fa-globe" aria-hidden />
                              </span>
                              <span className={styles.hostTextGroup}>
                                <span className={styles.hostText}>{site.host}</span>
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
                          <div className={styles.sslColStack}>
                            <span className={styles.statusPill}>{ssl}</span>
                            {sslLive ? (
                              <span
                                className={sslLive.phase === 'error' ? styles.sslAcmeLiveErr : styles.sslAcmeLive}
                                title={sslLive.message}
                                role="status"
                              >
                                <FaIcon className="fas fa-spinner" aria-hidden />{' '}
                                {formatAcmeSslPhase(sslLive.phase)}
                              </span>
                            ) : null}
                          </div>
                        </td>
                        <td className={styles.actionsCell}>
                          <div className={styles.rowActions}>
                            <button
                              type="button"
                              className={styles.rowActionBtn}
                              onClick={() => openEdit(i)}
                              disabled={saving}
                              title="Edit"
                              aria-label={`Edit ${site.host}`}
                            >
                              <FaIcon className="fas fa-edit" aria-hidden />
                            </button>
                            <button
                              type="button"
                              className={styles.rowActionBtn}
                              onClick={() => openDuplicate(i)}
                              disabled={saving}
                              title="Duplicate"
                              aria-label={`Duplicate ${site.host}`}
                            >
                              <FaIcon className="fas fa-copy" aria-hidden />
                            </button>
                            <button
                              type="button"
                              className={`${styles.rowActionBtn} ${styles.rowActionDanger}`}
                              onClick={() => setDeleteConfirmIndex(i)}
                              disabled={saving}
                              title="Delete"
                              aria-label={`Delete ${site.host}`}
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
              </div>

              <div className={styles.formSection}>
                <h3 className={styles.sectionTitle}>
                  <FaIcon className={`fas fa-lock ${styles.sectionIcon}`} aria-hidden />
                  SSL / TLS
                </h3>
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
                      <span className={styles.sslChoiceText}>Plain HTTP only</span>
                    </span>
                  </label>
                  <label className={formSslMode === 'existing_cert' ? styles.sslChoiceActive : styles.sslChoice}>
                    <input
                      type="radio"
                      name="sslMode"
                      checked={formSslMode === 'existing_cert'}
                      onChange={() => setFormSslMode('existing_cert')}
                      className={styles.radioInput}
                    />
                    <span className={styles.sslChoiceIcon}>
                      <FaIcon className="fas fa-certificate" aria-hidden />
                    </span>
                    <span>
                      <span className={styles.sslChoiceTitle}>Existing cert</span>
                      <span className={styles.sslChoiceText}>Reuse a configured certificate</span>
                    </span>
                  </label>
                  <label className={formSslMode === 'auto_ssl' ? styles.sslChoiceActive : styles.sslChoice}>
                    <input
                      type="radio"
                      name="sslMode"
                      checked={formSslMode === 'auto_ssl'}
                      onChange={() => setFormSslMode('auto_ssl')}
                      className={styles.radioInput}
                    />
                    <span className={styles.sslChoiceIcon}>
                      <FaIcon className="fas fa-magic" aria-hidden />
                    </span>
                    <span>
                      <span className={styles.sslChoiceTitle}>Auto Generate SSL</span>
                      <span className={styles.sslChoiceText}>ACME / Let&apos;s Encrypt</span>
                    </span>
                  </label>
                </div>
                {formSslMode === 'existing_cert' && (
                  <label className={styles.label}>
                    TLS certificate
                    <div className={styles.selectWrap}>
                      <FaIcon className={`fas fa-certificate ${styles.selectLeadIcon}`} aria-hidden />
                      <select
                      value={formCertName}
                      onChange={(e) => setFormCertName(e.target.value)}
                      className={`${styles.select} ${styles.selectWithLead}`}
                    >
                      <option value="">Select certificate…</option>
                      {issuedTlsCerts.map((r) => (
                        <option key={r.id} value={r.id}>
                          {(r.hosts?.length ? r.hosts.join(' · ') : r.id) + ` · ${r.source_type || 'tls'}`}
                        </option>
                      ))}
                    </select>
                    <FaIcon className={`fas fa-chevron-down ${styles.selectIcon}`} aria-hidden />
                    </div>
                  </label>
                )}
                {formSslMode === 'auto_ssl' && (
                  <>
                    <p className={styles.hint}>Certificate is generated automatically when you save (no restart).</p>
                    <label className={styles.label}>
                      Contact email (Let&apos;s Encrypt)
                      <input
                        type="email"
                        value={formContactEmail}
                        onChange={(e) => setFormContactEmail(e.target.value)}
                        placeholder="you@yourdomain.com"
                        className={styles.input}
                        required
                      />
                      <p className={styles.hint}>Required for Let&apos;s Encrypt account. Used for expiry notifications.</p>
                    </label>
                    <label className={styles.label}>
                      Challenge type
                      <div className={styles.selectWrap}>
                        <FaIcon className={`fas fa-shield-alt ${styles.selectLeadIcon}`} aria-hidden />
                        <select
                          value={formChallengeType}
                          onChange={(e) => {
                            const next = e.target.value as ChallengeType;
                            setFormChallengeType(next);
                            if (next !== 'dns-01') setFormDnsProviderName('');
                          }}
                          className={`${styles.select} ${styles.selectWithLead}`}
                        >
                          <option value="http-01">HTTP-01</option>
                          <option value="dns-01">DNS-01</option>
                        </select>
                        <FaIcon className={`fas fa-chevron-down ${styles.selectIcon}`} aria-hidden />
                      </div>
                    </label>
                    {formChallengeType === 'dns-01' && (
                      <label className={styles.label}>
                        DNS provider
                        <div className={styles.selectWrap}>
                          <FaIcon className={`fas fa-server ${styles.selectLeadIcon}`} aria-hidden />
                          <select
                            value={formDnsProviderName}
                            onChange={(e) => setFormDnsProviderName(e.target.value)}
                            className={`${styles.select} ${styles.selectWithLead}`}
                          >
                            <option value="">Select DNS provider…</option>
                            {dnsNames.map((d) => (
                              <option key={d} value={d}>
                                {d}
                              </option>
                            ))}
                          </select>
                          <FaIcon className={`fas fa-chevron-down ${styles.selectIcon}`} aria-hidden />
                        </div>
                      </label>
                    )}
                    <label className={styles.autoSslCheck}>
                      <input
                        type="checkbox"
                        checked={formWildcard}
                        onChange={(e) => {
                          const checked = e.target.checked;
                          setFormWildcard(checked);
                          if (checked) {
                            setFormChallengeType('dns-01');
                          }
                        }}
                      />
                      {`Wildcard certificate (${wildcardLabel})`}
                    </label>
                    {formWildcard && (
                      <p className={styles.hint}>
                        Wildcard is auto-generated for <code>*.{wildcardBaseFromHost(formHost)}</code> and{' '}
                        <code>{wildcardBaseFromHost(formHost)}</code>.
                      </p>
                    )}
                  </>
                )}
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

              <div className={styles.formSection}>
                <h3 className={styles.sectionTitle}>Security headers</h3>
                <div
                  className={`${styles.altSvcSupportBox} ${
                    !altSvcSupport.hasHttps
                      ? styles.altSvcSupportWarn
                      : !altSvcSupport.h3Listeners
                        ? styles.altSvcSupportMuted
                        : styles.altSvcSupportOk
                  }`}
                  role="status"
                >
                  {!altSvcSupport.hasHttps ? (
                    <>
                      <strong>No HTTPS listener configured.</strong> The <span className="mono">Alt-Svc</span> header is
                      only attached to <strong>HTTPS</strong> responses. Enable TLS / an HTTPS port in Settings before
                      this option can take effect.
                    </>
                  ) : (
                    <>
                      <strong>Alt-Svc supported.</strong> With the option below on, HTTPS responses include{' '}
                      <span className="mono">
                        Alt-Svc: h3=&quot;:{altSvcSupport.httpsPort}&quot;; ma=86400
                      </span>{' '}
                      (HTTP/3 on the same TLS port).{' '}
                      {altSvcSupport.h3Listeners ? (
                        <>This node exposes HTTP/3 (QUIC), so clients can upgrade.</>
                      ) : (
                        <>
                          QUIC HTTP/3 is not enabled in this deployment — clients may not successfully use HTTP/3 even if
                          they see the header.
                        </>
                      )}
                    </>
                  )}
                </div>
                <div className={styles.securitySectionWrap}>
                  <label className={styles.securityOption}>
                    <input
                      type="checkbox"
                      checked={formAdvertiseHttp3}
                      onChange={(e) => setFormAdvertiseHttp3(e.target.checked)}
                    />
                    <span className={styles.securityOptionTitle}>Advertise HTTP/3 (Alt-Svc) for this site</span>
                  </label>
                  <p className={styles.securityHintText}>
                    <strong>Unchecked</strong>: no <span className="mono">Alt-Svc</span> header — traffic stays on{' '}
                    <strong>HTTP/1.1</strong> or <strong>HTTP/2</strong> over TLS (ALPN: <span className="mono">http/1.1</span>{' '}
                    or <span className="mono">h2</span>), not HTTP/3 from this host. Clients that cached a previous Alt-Svc
                    may retry HTTP/3 until that cache expires.
                  </p>
                  <label className={styles.securityOption}>
                    <input
                      type="checkbox"
                      checked={formSecurityMode === 'override'}
                      onChange={(e) => setFormSecurityMode(e.target.checked ? 'override' : 'inherit')}
                    />
                    <span className={styles.securityOptionTitle}>Override global security headers for this site</span>
                  </label>
                  {formSecurityMode === 'override' ? (
                    <>
                      <textarea
                        className={styles.textarea}
                        value={formSecurityHeadersText}
                        onChange={(e) => setFormSecurityHeadersText(e.target.value)}
                        spellCheck={false}
                        rows={8}
                        placeholder="Strict-Transport-Security: max-age=63072000; includeSubDomains"
                      />
                      <p className={styles.securityHintText}>
                        One header per line (<span className="mono">Name: value</span>). Use an empty value to remove a
                        global header for this host. Per-site headers are merged on top of globals (same as pertisk-rproxy).
                      </p>
                    </>
                  ) : (
                    <p className={styles.securityHintText}>
                      Using global security headers from config. Add per-site lines above when you need an overlay for this
                      host only.
                    </p>
                  )}
                </div>
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
