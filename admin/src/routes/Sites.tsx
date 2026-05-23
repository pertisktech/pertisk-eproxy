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
  type K8sNamespaceRow,
  type K8sServiceRow,
  type K8sTlsSecretRow,
  type IngressFormRouteRow,
  type CreateIngressBody,
  normalizeDnsProviders,
} from '@/api/client';
import { getCookieValue, setCookieValue } from '@/auth';
import { useMode } from '@/context/ModeContext';
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

type DisplaySiteItem = {
  key: string;
  site: Site;
  index: number;
  sites: Site[];
  indices: number[];
};

function emptyIngressRoute(): IngressFormRouteRow {
  return {
    path: '/',
    path_type: 'Prefix',
    service_name: '',
    service_port: null,
    service_port_name: '',
  };
}

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
  const [formOverrideSecurityHeaders, setFormOverrideSecurityHeaders] = useState(false);
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
  const [showIngressForm, setShowIngressForm] = useState(false);
  const [ingressHost, setIngressHost] = useState('');
  const [ingressNamespace, setIngressNamespace] = useState('');
  const [ingressTlsNamespace, setIngressTlsNamespace] = useState('');
  const [ingressTlsName, setIngressTlsName] = useState('');
  const [ingressServiceNamespace, setIngressServiceNamespace] = useState('');
  const [ingressRoutes, setIngressRoutes] = useState<IngressFormRouteRow[]>([emptyIngressRoute()]);
  const [ingressFormError, setIngressFormError] = useState<string | null>(null);
  const [ingressSaving, setIngressSaving] = useState(false);
  const [k8sNamespaces, setK8sNamespaces] = useState<K8sNamespaceRow[]>([]);
  const [k8sTlsSecrets, setK8sTlsSecrets] = useState<K8sTlsSecretRow[]>([]);
  const [k8sServices, setK8sServices] = useState<K8sServiceRow[]>([]);
  const [editingIngressRef, setEditingIngressRef] = useState<{ namespace: string; name: string } | null>(null);
  const [deleteConfirmIngress, setDeleteConfirmIngress] = useState<{ namespace: string; name: string } | null>(null);
  const toast = useToast();
  const mode = useMode();
  const readOnly = mode === 'ingress';
  const wildcardLabel = wildcardDomainFromHost(formHost);

  const sites = config?.sites ?? EMPTY_SITES;
  const backends = config?.backends ?? EMPTY_BACKENDS;
  const dnsNames = useMemo(
    () => normalizeDnsProviders(config?.dns_providers).map((e) => e.name).filter((n) => n.length > 0),
    [config?.dns_providers],
  );

  const displaySiteItems: DisplaySiteItem[] = useMemo(() => {
    if (mode !== 'ingress') {
      return sites.map((site, index) => ({
        key: `${site.host}-${index}`,
        site,
        index,
        sites: [site],
        indices: [index],
      }));
    }
    const groups = new Map<string, DisplaySiteItem>();
    sites.forEach((site, index) => {
      const ingressNamespace = site.ingress_namespace?.trim();
      const ingressName = site.ingress_name?.trim();
      const groupKey =
        ingressNamespace && ingressName
          ? `${ingressNamespace}/${ingressName}`
          : `host::${site.host}`;
      const existing = groups.get(groupKey);
      if (existing) {
        existing.sites.push(site);
        existing.indices.push(index);
      } else {
        groups.set(groupKey, {
          key: groupKey,
          site,
          index,
          sites: [site],
          indices: [index],
        });
      }
    });
    return Array.from(groups.values());
  }, [sites, mode]);

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

  function upstreamsForItem(item: DisplaySiteItem): string[] {
    return Array.from(new Set(item.sites.map((site) => upstreamForSite(site)).filter(Boolean)));
  }

  function routesForItem(item: DisplaySiteItem): PathRewrite[] {
    const deduped = new Map<string, PathRewrite>();
    item.sites.forEach((site) => {
      (site.routes ?? []).forEach((route) => {
        const key = `${route.path_type || 'prefix'}::${route.path}::${route.rewrite ?? ''}`;
        if (!deduped.has(key)) deduped.set(key, route);
      });
    });
    return Array.from(deduped.values());
  }

  function sslLabelForSite(site: Site): string {
    const v = site.certificate?.trim();
    if (!v) return '—';
    if (v.startsWith('k8s/')) {
      const ref = v.slice(4);
      return ref.includes('/') ? `TLS ${ref}` : ref;
    }
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
        if (sortKey === 'upstream') {
          const upA = mode === 'ingress' ? upstreamsForItem(a).join(', ') : upstreamForSite(a.site);
          const upB = mode === 'ingress' ? upstreamsForItem(b).join(', ') : upstreamForSite(b.site);
          return dir * compareStrings(upA, upB);
        }
        if (sortKey === 'routes') {
          const rA = mode === 'ingress' ? routesForItem(a).length : (a.site.routes?.length ?? 0);
          const rB = mode === 'ingress' ? routesForItem(b).length : (b.site.routes?.length ?? 0);
          return dir * (rA - rB);
        }
        return dir * compareStrings(sslLabelForSite(a.site), sslLabelForSite(b.site));
      })
    : displaySiteItems;

  const pagedSiteItems = sortedSiteItems.slice(startIndex, endIndexExclusive);

  function updateViewMode(next: 'card' | 'list') {
    setViewMode(next);
    setCookieValue(VIEW_MODE_COOKIE, next, VIEW_MODE_MAX_AGE_SECS);
  }

  const load = useCallback(async (opts?: { silent?: boolean }): Promise<ProxyConfig | null> => {
    const silent = opts?.silent === true;
    if (!silent) {
      setLoading(true);
    }
    setError(null);
    try {
      const [nextConfig, certList] = await Promise.all([
        api.config(),
        api.certificates.list().catch(() => [] as CertificateRow[]),
      ]);
      const certs = Array.isArray(certList) ? certList : [];
      setConfig(nextConfig);
      setIssuedTlsCerts(certs);
      sitesCache = {
        config: nextConfig,
        issuedTlsCerts: certs,
      };
      return nextConfig;
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Failed to load config');
      if (sitesCache == null) {
        setConfig(null);
        setIssuedTlsCerts([]);
      }
      return null;
    } finally {
      if (!silent) {
        setLoading(false);
      }
    }
  }, []);

  async function refreshSitesAfterIngressWrite(host: string) {
    const want = host.trim().toLowerCase();
    for (let attempt = 0; attempt < 12; attempt++) {
      const cfg = await load({ silent: true });
      const found = (cfg?.sites ?? []).some((s) => s.host.trim().toLowerCase() === want);
      if (found) return;
      await new Promise((r) => window.setTimeout(r, 500));
    }
  }

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
    if (!showForm && !showIngressForm) return;
    const root = document.documentElement;
    root.classList.add('eproxy-scroll-lock');
    return () => {
      root.classList.remove('eproxy-scroll-lock');
    };
  }, [showForm, showIngressForm]);

  useEffect(() => {
    if (showForm || showIngressForm || saving || ingressSaving) return;
    let cancelled = false;
    async function refreshConfig() {
      if (document.visibilityState !== 'visible') return;
      try {
        const next = await api.config();
        if (!cancelled) setConfig(next);
      } catch {
        /* keep existing */
      }
    }
    const t = setInterval(refreshConfig, 5000);
    return () => {
      cancelled = true;
      clearInterval(t);
    };
  }, [showForm, showIngressForm, saving, ingressSaving]);

  useEffect(() => {
    if (mode !== 'ingress' || !showIngressForm) return;
    api.kubernetes.namespaces().then(setK8sNamespaces).catch(() => setK8sNamespaces([]));
    api.kubernetes.tlsSecrets().then(setK8sTlsSecrets).catch(() => setK8sTlsSecrets([]));
  }, [mode, showIngressForm]);

  useEffect(() => {
    if (mode !== 'ingress' || !ingressServiceNamespace.trim()) {
      setK8sServices([]);
      return;
    }
    api.kubernetes
      .services({ namespace: ingressServiceNamespace.trim() })
      .then(setK8sServices)
      .catch(() => setK8sServices([]));
  }, [mode, ingressServiceNamespace]);

  useEffect(() => {
    setIngressRoutes((routes) => {
      let changed = false;
      const next = routes.map((route) => {
        const serviceName = route.service_name.trim();
        if (!serviceName) {
          if (route.service_port == null && !(route.service_port_name ?? '').trim()) return route;
          changed = true;
          return { ...route, service_port: null, service_port_name: '' };
        }
        const service = k8sServices.find((item) => item.name === serviceName);
        const ports = service?.ports_detail ?? [];
        if (ports.length === 0) {
          if (route.service_port == null && !(route.service_port_name ?? '').trim()) return route;
          changed = true;
          return { ...route, service_port: null, service_port_name: '' };
        }
        if (route.service_port != null && ports.some((port) => port.port === route.service_port)) {
          return route;
        }
        const byName = (route.service_port_name ?? '').trim()
          ? ports.find((port) => port.name === route.service_port_name?.trim())
          : undefined;
        const resolvedPort = byName?.port ?? ports[0]?.port ?? null;
        const resolvedName = byName?.name ?? '';
        if (resolvedPort === route.service_port && resolvedName === (route.service_port_name ?? '')) {
          return route;
        }
        changed = true;
        return { ...route, service_port: resolvedPort, service_port_name: resolvedName };
      });
      return changed ? next : routes;
    });
  }, [k8sServices]);

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

  function ingressPortsForService(serviceName: string) {
    return k8sServices.find((service) => service.name === serviceName.trim())?.ports_detail ?? [];
  }

  function addIngressRoute() {
    setIngressRoutes((routes) => [...routes, emptyIngressRoute()]);
  }

  function removeIngressRoute(index: number) {
    setIngressRoutes((routes) =>
      routes.length > 1 ? routes.filter((_, routeIndex) => routeIndex !== index) : routes,
    );
  }

  function updateIngressRoute(index: number, patch: Partial<IngressFormRouteRow>) {
    setIngressRoutes((routes) =>
      routes.map((route, routeIndex) => {
        if (routeIndex !== index) return route;
        const next = { ...route, ...patch };
        if (Object.prototype.hasOwnProperty.call(patch, 'service_name')) {
          next.service_port = null;
          next.service_port_name = '';
        }
        return next;
      }),
    );
  }

  function openIngressAdd() {
    setEditingIngressRef(null);
    setIngressHost('');
    setIngressNamespace('');
    setIngressTlsNamespace('');
    setIngressTlsName('');
    setIngressServiceNamespace('');
    setIngressRoutes([emptyIngressRoute()]);
    setIngressFormError(null);
    setShowForm(false);
    setShowIngressForm(true);
  }

  async function openIngressEdit(site: Site) {
    const ns = site.ingress_namespace?.trim();
    const name = site.ingress_name?.trim();
    if (!ns || !name) return;
    setIngressFormError(null);
    try {
      const row = await api.kubernetes.getIngress(ns, name);
      setEditingIngressRef({ namespace: row.namespace, name: row.name });
      setIngressHost(row.host);
      setIngressNamespace(row.namespace);
      setIngressTlsNamespace(
        row.tls_secret_name ? (row.tls_secret_namespace ?? row.namespace) : '',
      );
      setIngressTlsName(row.tls_secret_name ?? '');
      setIngressServiceNamespace(row.namespace);
      setIngressRoutes(
        row.routes?.length
          ? row.routes.map((route) => ({
              path: route.path || '/',
              path_type: route.path_type || 'Prefix',
              service_name: route.service_name || '',
              service_port: route.service_port ?? null,
              service_port_name: route.service_port_name ?? '',
            }))
          : [
              {
                path: row.path || '/',
                path_type: row.path_type || 'Prefix',
                service_name: row.service_name || '',
                service_port: row.service_port ?? null,
                service_port_name: row.service_port_name ?? '',
              },
            ],
      );
      setShowForm(false);
      setShowIngressForm(true);
    } catch (err) {
      toast.error(err instanceof Error ? err.message : 'Failed to load Ingress');
    }
  }

  function openIngressDeleteConfirm(site: Site) {
    const ns = site.ingress_namespace?.trim();
    const ingName = site.ingress_name?.trim();
    if (ns && ingName) setDeleteConfirmIngress({ namespace: ns, name: ingName });
  }

  async function deleteIngressSite() {
    if (!deleteConfirmIngress) return;
    const { namespace, name } = deleteConfirmIngress;
    setDeleteConfirmIngress(null);
    setIngressSaving(true);
    try {
      await api.kubernetes.deleteIngress(namespace, name);
      await load({ silent: true });
      toast.success('Ingress deleted.');
    } catch (err) {
      toast.error(err instanceof Error ? err.message : 'Failed to delete Ingress');
    } finally {
      setIngressSaving(false);
    }
  }

  async function handleIngressSubmit(e: FormEvent) {
    e.preventDefault();
    setIngressFormError(null);
    const host = ingressHost.trim();
    if (!host) {
      setIngressFormError('Host is required');
      return;
    }
    const serviceNamespace = ingressServiceNamespace.trim();
    if (!serviceNamespace) {
      setIngressFormError('Service namespace is required');
      return;
    }
    const routes = ingressRoutes
      .map((route) => {
        const path = route.path.trim() || '/';
        const pathType = route.path_type?.trim() || 'Prefix';
        const serviceName = route.service_name.trim();
        const ports = ingressPortsForService(serviceName);
        const selectedPort =
          route.service_port != null ? ports.find((port) => port.port === route.service_port) : undefined;
        const namedPort = (route.service_port_name ?? '').trim()
          ? ports.find((port) => port.name === route.service_port_name?.trim())
          : undefined;
        const portNum = selectedPort?.port ?? namedPort?.port ?? route.service_port ?? null;
        return {
          path,
          path_type: pathType,
          service_name: serviceName,
          service_port: portNum,
          service_port_name: namedPort?.name ?? '',
        };
      })
      .filter((route) => route.path);
    if (routes.length === 0) {
      setIngressFormError('At least one route is required');
      return;
    }
    for (const route of routes) {
      if (!route.service_name) {
        setIngressFormError('Each route requires a service');
        return;
      }
      if (route.service_port == null) {
        setIngressFormError(`Select a service port for ${route.path}`);
        return;
      }
    }
    const firstRoute = routes[0];
    const ingressNs = ingressNamespace.trim() || serviceNamespace;
    const tlsNs = ingressTlsNamespace.trim() || ingressNs;
    const tlsName = ingressTlsName.trim();
    if (tlsName && tlsNs !== ingressNs) {
      setIngressFormError(
        `TLS secret must be in the Ingress namespace (${ingressNs}). Copy the secret or choose one from that namespace.`,
      );
      return;
    }
    setIngressSaving(true);
    try {
      const body: CreateIngressBody = {
        host,
        routes,
        path: firstRoute.path,
        path_type: firstRoute.path_type,
        service_namespace: serviceNamespace,
        service_name: firstRoute.service_name,
        service_port: firstRoute.service_port ?? undefined,
        service_port_name: firstRoute.service_port_name || undefined,
        ingress_namespace: ingressNs,
      };
      if (tlsName) {
        body.tls_secret_namespace = ingressNs;
        body.tls_secret_name = tlsName;
      }
      if (editingIngressRef) {
        await api.kubernetes.updateIngress(editingIngressRef.namespace, editingIngressRef.name, body);
        setEditingIngressRef(null);
        toast.success('Ingress updated.');
      } else {
        await api.kubernetes.createIngress(body);
        toast.success('Ingress created.');
      }
      setShowIngressForm(false);
      await refreshSitesAfterIngressWrite(host);
    } catch (err) {
      const msg = err instanceof Error ? err.message : 'Failed to save Ingress';
      setIngressFormError(msg);
      toast.error(msg);
    } finally {
      setIngressSaving(false);
    }
  }

  function openAdd() {
    if (mode === 'ingress') {
      openIngressAdd();
      return;
    }
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
    setFormOverrideSecurityHeaders(false);
    setFormError(null);
    setShowIngressForm(false);
    setShowForm(true);
  }

  function openEdit(index: number) {
    if (mode === 'ingress') return;
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
    setFormOverrideSecurityHeaders(false);
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
    setFormOverrideSecurityHeaders(false);
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
          {(!readOnly || mode === 'ingress') && (
            <button
              type="button"
              className={styles.btnPrimary}
              onClick={openAdd}
              disabled={saving || ingressSaving || mode == null}
              title={mode == null ? 'Loading mode…' : undefined}
            >
              <FaIcon className="fas fa-plus" aria-hidden /> Add Site
            </button>
          )}
        </div>
      </div>

      {config && (
        <>
          {sites.length === 0 ? (
            <div className={styles.emptyState}>
              <FaIcon className="fas fa-globe" size={48} aria-hidden />
              <h3 className={styles.emptyTitle}>No sites configured</h3>
              <p className={styles.emptyText}>
                {mode === 'ingress'
                  ? 'Create a Kubernetes Ingress to add a site (host, TLS secret, backend service)'
                  : 'Get started by adding your first reverse proxy site'}
              </p>
              {(!readOnly || mode === 'ingress') && (
                <button type="button" className={styles.btnPrimary} onClick={openAdd} disabled={saving || ingressSaving}>
                  <FaIcon className="fas fa-plus" aria-hidden /> Add Your First Site
                </button>
              )}
            </div>
          ) : viewMode === 'card' ? (
            <div className={styles.cardGrid}>
              {pagedSiteItems.map((item) => {
                const { site, index: i } = item;
                const upstreams = upstreamsForItem(item);
                const routes = routesForItem(item);
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
                        {upstreams.length <= 1 ? (
                          <span className={styles.metaValue}>{upstreams[0] ?? '—'}</span>
                        ) : (
                          <div className={styles.routes}>
                            {upstreams.map((upstream) => (
                              <span key={upstream} className={styles.routeChip}>
                                {upstream}
                              </span>
                            ))}
                          </div>
                        )}
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
                        {readOnly && !(site.ingress_namespace && site.ingress_name) ? (
                          <span className={styles.readOnlyHint} title="View only (no Ingress ref)">
                            <FaIcon className="fas fa-eye" aria-hidden /> View only
                          </span>
                        ) : readOnly && site.ingress_namespace && site.ingress_name ? (
                          <>
                            <button
                              type="button"
                              className={styles.btnEdit}
                              onClick={() => openIngressEdit(site)}
                              disabled={ingressSaving}
                              title="Edit Ingress"
                            >
                              <FaIcon className="fas fa-edit" aria-hidden /> Edit
                            </button>
                            <button
                              type="button"
                              className={styles.btnDanger}
                              onClick={() => openIngressDeleteConfirm(site)}
                              disabled={ingressSaving}
                              title="Delete Ingress"
                            >
                              <FaIcon className="fas fa-trash" aria-hidden /> Delete
                            </button>
                          </>
                        ) : (
                          <>
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
                          </>
                        )}
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
                    const upstreams = upstreamsForItem(item);
                    const routes = routesForItem(item);
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
                            <span className={styles.monoPrimary} title={upstreams.join(', ')}>
                              {upstreams[0] ?? '—'}
                            </span>
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
                            {readOnly && !(site.ingress_namespace && site.ingress_name) ? (
                              <span className={styles.readOnlyHint} title="View only">
                                <FaIcon className="fas fa-eye" aria-hidden />
                              </span>
                            ) : readOnly && site.ingress_namespace && site.ingress_name ? (
                              <>
                                <button
                                  type="button"
                                  className={styles.rowActionBtn}
                                  onClick={() => openIngressEdit(site)}
                                  disabled={ingressSaving}
                                  title="Edit Ingress"
                                  aria-label={`Edit Ingress ${site.host}`}
                                >
                                  <FaIcon className="fas fa-edit" aria-hidden />
                                </button>
                                <button
                                  type="button"
                                  className={`${styles.rowActionBtn} ${styles.rowActionDanger}`}
                                  onClick={() => openIngressDeleteConfirm(site)}
                                  disabled={ingressSaving}
                                  title="Delete Ingress"
                                  aria-label={`Delete Ingress ${site.host}`}
                                >
                                  <FaIcon className="fas fa-trash" aria-hidden />
                                </button>
                              </>
                            ) : (
                              <>
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
                              </>
                            )}
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

      {showForm && mode !== 'ingress' &&
        createPortal(
          <div
            className={styles.modalBackdrop}
            role="presentation"
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
                <h3 className={styles.sectionTitle}>Protocol & Security</h3>
                <div className={styles.securitySectionWrap}>
                  <label className={styles.securityOption}>
                    <input
                      type="checkbox"
                      checked={formAdvertiseHttp3}
                      onChange={(e) => setFormAdvertiseHttp3(e.target.checked)}
                    />
                    <span className={styles.securityOptionTitle}>Advertise HTTP/3 (Alt-Svc) for this site</span>
                  </label>
                  <label className={styles.securityOption}>
                    <input
                      type="checkbox"
                      checked={formOverrideSecurityHeaders}
                      onChange={(e) => setFormOverrideSecurityHeaders(e.target.checked)}
                    />
                    <span className={styles.securityOptionTitle}>Override global security headers for this site</span>
                  </label>
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

      {showIngressForm &&
        createPortal(
          <div
            className={styles.modalBackdrop}
            role="presentation"
          >
            <div className={`${styles.modal} ${styles.modalIngressWide}`} role="dialog" aria-modal="true">
              <div className={styles.modalHeader}>
                <h2>
                  <FaIcon className={editingIngressRef ? 'fas fa-pen-to-square' : 'fas fa-plus'} aria-hidden />{' '}
                  {editingIngressRef ? 'Edit Ingress' : 'Add Site (create Ingress)'}
                </h2>
                <button
                  type="button"
                  className={styles.modalClose}
                  onClick={() => setShowIngressForm(false)}
                  aria-label="Close"
                >
                  <FaIcon className="fas fa-times" aria-hidden />
                </button>
              </div>
              <form onSubmit={handleIngressSubmit} className={styles.modalForm}>
                <div className={styles.formSection}>
                  <label className={styles.label}>
                    Host
                    <input
                      type="text"
                      value={ingressHost}
                      onChange={(e) => setIngressHost(e.target.value)}
                      placeholder="example.com"
                      className={styles.input}
                      required
                    />
                  </label>
                </div>
                <div className={styles.formSection}>
                  <label className={styles.label}>
                    Ingress namespace
                    <div className={styles.selectWrap}>
                      <select
                        value={ingressNamespace || ingressServiceNamespace}
                        onChange={(e) => setIngressNamespace(e.target.value)}
                        className={styles.select}
                        required
                      >
                        {k8sNamespaces.map((n) => (
                          <option key={n.name} value={n.name}>
                            {n.name}
                          </option>
                        ))}
                      </select>
                      <FaIcon className={`fas fa-chevron-down ${styles.selectIcon}`} aria-hidden />
                    </div>
                  </label>
                </div>
                <div className={styles.formSection}>
                  <label className={styles.label}>
                    Certificate (TLS Secret)
                    <div className={styles.selectWrap}>
                      <select
                        value={
                          ingressTlsNamespace && ingressTlsName
                            ? `${ingressTlsNamespace}/${ingressTlsName}`
                            : ''
                        }
                        onChange={(e) => {
                          const v = e.target.value;
                          if (!v) {
                            setIngressTlsNamespace('');
                            setIngressTlsName('');
                          } else {
                            const [ns, name] = v.split('/');
                            setIngressTlsNamespace(ns ?? '');
                            setIngressTlsName(name ?? '');
                          }
                        }}
                        className={styles.select}
                      >
                        <option value=""> </option>
                        {(() => {
                          const ingressNs = ingressNamespace.trim() || ingressServiceNamespace.trim();
                          const secrets = ingressNs
                            ? k8sTlsSecrets.filter((s) => s.namespace === ingressNs)
                            : k8sTlsSecrets;
                          return secrets;
                        })().map((s) => (
                          <option key={`${s.namespace}/${s.name}`} value={`${s.namespace}/${s.name}`}>
                            {s.namespace}/{s.name}
                          </option>
                        ))}
                      </select>
                      <FaIcon className={`fas fa-chevron-down ${styles.selectIcon}`} aria-hidden />
                    </div>
                  </label>
                </div>
                <div className={styles.formSection}>
                  <label className={styles.label}>
                    Service namespace
                    <div className={styles.selectWrap}>
                      <select
                        value={ingressServiceNamespace}
                        onChange={(e) => {
                          const ns = e.target.value;
                          setIngressServiceNamespace(ns);
                          setIngressRoutes((routes) =>
                            routes.map((route) => ({
                              ...route,
                              service_name: '',
                              service_port: null,
                              service_port_name: '',
                            })),
                          );
                          const effectiveIngressNs = ingressNamespace.trim() || ns;
                          if (ingressTlsNamespace && ingressTlsNamespace !== effectiveIngressNs) {
                            setIngressTlsNamespace('');
                            setIngressTlsName('');
                          }
                        }}
                        className={styles.select}
                        required
                      >
                        {k8sNamespaces.map((n) => (
                          <option key={n.name} value={n.name}>
                            {n.name}
                          </option>
                        ))}
                      </select>
                      <FaIcon className={`fas fa-chevron-down ${styles.selectIcon}`} aria-hidden />
                    </div>
                  </label>
                </div>
                <div className={styles.formSection}>
                  <div className={styles.routesHeader}>
                    <button type="button" className={styles.btnSecondary} onClick={addIngressRoute}>
                      Add route
                    </button>
                  </div>
                  <div className={styles.ingressRoutesList}>
                    {ingressRoutes.map((route, index) => {
                      const servicePorts = ingressPortsForService(route.service_name);
                      return (
                        <div key={`${index}-${route.path}-${route.service_name}`} className={styles.ingressRouteCard}>
                          <div className={styles.ingressRouteHeader}>
                            <span className={styles.ingressRouteTitle}>Route {index + 1}</span>
                            <button
                              type="button"
                              className={styles.btnDanger}
                              onClick={() => removeIngressRoute(index)}
                              disabled={ingressRoutes.length === 1}
                              title="Remove route"
                            >
                              <FaIcon className="fas fa-times" aria-hidden />
                            </button>
                          </div>
                          <div className={styles.ingressRouteGrid}>
                            <label className={styles.label}>
                              Path
                              <input
                                type="text"
                                value={route.path}
                                onChange={(e) => updateIngressRoute(index, { path: e.target.value })}
                                placeholder="/api"
                                className={styles.input}
                              />
                            </label>
                            <label className={styles.label}>
                              Path type
                              <div className={styles.selectWrap}>
                                <select
                                  value={route.path_type || 'Prefix'}
                                  onChange={(e) => updateIngressRoute(index, { path_type: e.target.value })}
                                  className={styles.select}
                                >
                                  {PATH_TYPES.map((t) => (
                                    <option key={t} value={t}>
                                      {t}
                                    </option>
                                  ))}
                                </select>
                                <FaIcon className={`fas fa-chevron-down ${styles.selectIcon}`} aria-hidden />
                              </div>
                            </label>
                            <label className={styles.label}>
                              Service
                              <div className={styles.selectWrap}>
                                <select
                                  value={route.service_name}
                                  onChange={(e) => updateIngressRoute(index, { service_name: e.target.value })}
                                  className={styles.select}
                                  required
                                  disabled={!ingressServiceNamespace}
                                >
                                  <option value="">— Select service —</option>
                                  {k8sServices.map((service) => (
                                    <option key={`${service.namespace}-${service.name}`} value={service.name}>
                                      {service.name}
                                    </option>
                                  ))}
                                </select>
                                <FaIcon className={`fas fa-chevron-down ${styles.selectIcon}`} aria-hidden />
                              </div>
                            </label>
                            <label className={styles.label}>
                              Service port
                              <div className={styles.selectWrap}>
                                <select
                                  value={route.service_port != null ? String(route.service_port) : ''}
                                  onChange={(e) => {
                                    const value = e.target.value;
                                    updateIngressRoute(index, {
                                      service_port: value ? parseInt(value, 10) : null,
                                      service_port_name: '',
                                    });
                                  }}
                                  className={styles.select}
                                  required
                                  disabled={servicePorts.length === 0}
                                >
                                  <option value="">— Select port —</option>
                                  {servicePorts.map((port, portIndex) => (
                                    <option key={portIndex} value={String(port.port)}>
                                      {port.name != null && port.name !== ''
                                        ? `${port.name} (${port.port}, ${port.protocol})`
                                        : `${port.port} (${port.protocol})`}
                                    </option>
                                  ))}
                                </select>
                                <FaIcon className={`fas fa-chevron-down ${styles.selectIcon}`} aria-hidden />
                              </div>
                            </label>
                          </div>
                        </div>
                      );
                    })}
                  </div>
                </div>
                {ingressFormError && <p className={styles.formError}>{ingressFormError}</p>}
                <div className={styles.modalActions}>
                  <button type="button" className={styles.btnSecondary} onClick={() => setShowIngressForm(false)}>
                    Cancel
                  </button>
                  <button type="submit" className={styles.btnPrimary} disabled={ingressSaving}>
                    {ingressSaving
                      ? editingIngressRef
                        ? 'Updating…'
                        : 'Creating…'
                      : editingIngressRef
                        ? 'Update Ingress'
                        : 'Create Ingress'}
                  </button>
                </div>
              </form>
            </div>
          </div>,
          document.body,
        )}

      <ConfirmDialog
        open={deleteConfirmIngress !== null}
        title="Delete Ingress?"
        message={
          deleteConfirmIngress
            ? `Delete Ingress "${deleteConfirmIngress.name}" in namespace "${deleteConfirmIngress.namespace}"? This cannot be undone.`
            : 'Delete this Ingress?'
        }
        primaryLabel="Delete"
        cancelLabel="Cancel"
        variant="danger"
        loading={ingressSaving}
        onConfirm={() => void deleteIngressSite()}
        onCancel={() => setDeleteConfirmIngress(null)}
      />

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
