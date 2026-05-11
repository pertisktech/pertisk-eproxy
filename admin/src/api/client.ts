import { clearToken, clearUsername, getToken } from '@/auth';
import { SUPPORTED_DNS_PROVIDERS } from '@/data/supportedDnsProviders';

const API = '/api';

// ---------------------------------------------------------------------------
// Types — eProxy config / sites / backends
// ---------------------------------------------------------------------------

export interface Upstream {
  addr: string;
  weight: number;
}

export interface UpstreamStatus extends Upstream {
  healthy: boolean;
  conns: number;
}

export type LbAlgorithm = 'round_robin' | 'least_connections' | 'ip_hash';
export type PathType = 'exact' | 'prefix';

export interface PathRewrite {
  path: string;
  path_type: PathType;
  rewrite?: string;
}

export interface Site {
  host: string;
  backend: string;
  certificate?: string | null;
  dns_provider?: string | null;
  challenge_type?: 'http-01' | 'dns-01' | null;
  wildcard?: boolean | null;
  advertise_http3?: boolean | null;
  acme_contact_email?: string | null;
  routes: PathRewrite[];
}

export interface Backend {
  name: string;
  algorithm: LbAlgorithm;
  upstreams: Upstream[];
  health_path?: string | null;
  health_interval_secs: number;
}

export interface BackendStatus {
  name: string;
  algorithm: LbAlgorithm;
  upstreams: UpstreamStatus[];
}

/** Entry as returned by GET /api/config (after JSON parse). */
export interface DnsProviderConfigEntry {
  name: string;
  provider_type: string;
  credentials: Record<string, string>;
}

export type DnsProviderJson = string | DnsProviderConfigEntry;

export interface ProxyConfig {
  mode: 'proxy' | 'proxy_admin';
  http_port: number;
  management_port: number;
  certificates: string[];
  /** Legacy: string labels, or structured `{ name, provider_type, credentials }` from the API. */
  dns_providers?: DnsProviderJson[];
  sites: Site[];
  backends: Backend[];
  https_port?: number | null;
  quic_enabled?: boolean | null;
  quic_port?: number | null;
  tls_cert_file?: string | null;
  tls_key_file?: string | null;
}

/** DNS provider row (rproxy-compatible shape; eProxy stores names in `dns_providers` only). */
export type DnsProviderType = string;

const DNS_LABEL_PROVIDER_ID = 'label';

/** Known DNS integration ids from `supportedDnsProviders.ts` (upgrade legacy string-only entries). */
const SUPPORTED_DNS_PROVIDER_IDS = new Set(SUPPORTED_DNS_PROVIDERS.map((p) => p.id));

function inferProviderTypeFromLegacy(name: string, explicitType: string | undefined): string {
  const t = (explicitType ?? '').trim();
  if (t) return t;
  const n = (name ?? '').trim();
  if (n && SUPPORTED_DNS_PROVIDER_IDS.has(n)) return n;
  return DNS_LABEL_PROVIDER_ID;
}

/** Normalize `dns_providers` from config (legacy strings or objects) for the admin UI. */
export function normalizeDnsProviders(raw: unknown): DnsProviderConfigEntry[] {
  if (!Array.isArray(raw)) return [];
  return raw.map((entry: unknown) => {
    if (typeof entry === 'string') {
      const name = entry.trim();
      const provider_type = inferProviderTypeFromLegacy(name, undefined);
      return { name, provider_type, credentials: {} };
    }
    if (entry && typeof entry === 'object' && !Array.isArray(entry)) {
      const o = entry as Record<string, unknown>;
      const rawName = o.name;
      const name =
        typeof rawName === 'string'
          ? rawName
          : rawName != null && typeof rawName !== 'object'
            ? String(rawName)
            : '';
      const rawPt = o.provider_type;
      const explicitPt =
        typeof rawPt === 'string'
          ? rawPt.trim()
          : rawPt != null && typeof rawPt !== 'object'
            ? String(rawPt).trim()
            : '';
      const provider_type = inferProviderTypeFromLegacy(name, explicitPt || undefined);
      const credentials: Record<string, string> = {};
      const credRaw = o.credentials;
      if (credRaw && typeof credRaw === 'object' && !Array.isArray(credRaw)) {
        for (const [k, v] of Object.entries(credRaw)) {
          if (v != null && String(v).length > 0) credentials[k] = String(v);
        }
      }
      return { name, provider_type, credentials };
    }
    return { name: '', provider_type: DNS_LABEL_PROVIDER_ID, credentials: {} };
  });
}

function dnsProvidersForPut(entries: DnsProviderConfigEntry[]): DnsProviderConfigEntry[] {
  return entries.map((e) => ({
    name: e.name,
    provider_type: e.provider_type || DNS_LABEL_PROVIDER_ID,
    credentials: e.credentials ?? {},
  }));
}

/** Coalesce null/invalid list fields so PUT /api/config never sends JSON `null` for arrays. */
function prepareConfigForPut(c: ProxyConfig): ProxyConfig {
  const sites = Array.isArray(c.sites) ? c.sites : [];
  const backends = Array.isArray(c.backends) ? c.backends : [];
  return {
    ...c,
    sites: sites.map((s) => ({
      ...s,
      routes: Array.isArray(s.routes) ? s.routes : [],
    })),
    backends: backends.map((b) => ({
      ...b,
      upstreams: Array.isArray(b.upstreams) ? b.upstreams : [],
    })),
    certificates: Array.isArray(c.certificates) ? c.certificates : [],
    dns_providers: Array.isArray(c.dns_providers) ? c.dns_providers : [],
  };
}

export interface DnsProviderRow {
  id: string;
  name: string;
  provider_type: DnsProviderType;
  credentials?: Record<string, string> | null;
  created_at: string;
}

export interface SupportedDnsProviderField {
  key: string;
  label: string;
  type: string;
  required: boolean;
}

export interface SupportedDnsProvider {
  id: string;
  name: string;
  fields: SupportedDnsProviderField[];
}

function dnsProviderRowsFromConfig(c: ProxyConfig): DnsProviderRow[] {
  const entries = normalizeDnsProviders(c.dns_providers);
  return entries.map((e, i) => ({
    id: String(i),
    name: e.name,
    provider_type: e.provider_type,
    credentials: Object.keys(e.credentials ?? {}).length ? { ...e.credentials } : null,
    created_at: '',
  }));
}

export interface HealthReport {
  backends: Array<{
    name: string;
    total: number;
    healthy: number;
  }>;
}

// ---------------------------------------------------------------------------
// Types — shared admin shell (rproxy-compatible subset)
// ---------------------------------------------------------------------------

export type Health = { status: string };

export type Metrics = {
  log_entries: number;
  uptime_secs: number;
  http_requests_total: number;
  https_requests_total: number;
  grpc_requests_total: number;
  h2_requests_total: number;
  h3_requests_total: number;
  h3_vs_h2_ratio: number;
  site_h2_requests_total: Record<string, number>;
  site_h3_requests_total: Record<string, number>;
  site_h3_vs_h2_ratio: Record<string, number>;
  active_connections: number;
  connections_per_site: Record<string, number>;
  bytes_sent_total: number;
  bytes_received_total: number;
};

export type LogLevel = 'debug' | 'info' | 'warn' | 'error';
export type LogEntryType = 'request' | 'response' | 'health_check' | 'config_reload' | 'error' | 'proxy' | 'system';

export interface LogEntry {
  timestamp: string;
  level: LogLevel;
  host?: string;
  path?: string;
  upstream?: string;
  status?: number;
  duration_ms?: number;
  message: string;
  type: LogEntryType;
  protocol?: string | null;
  encoding?: string | null;
  method?: string | null;
}

export interface LoginResponse {
  token: string;
  username?: string;
  expires_in?: number;
}

export interface AuthRefreshResponse {
  token: string;
  username?: string;
  expires_in?: number;
}

export interface AuthCheckResponse {
  authenticated: boolean;
  username?: string;
}

export interface AuthConfigResponse {
  mode: 'local' | 'sso' | 'both';
  supports_local: boolean;
  supports_sso: boolean;
  auth0_domain?: string;
  auth0_client_id?: string;
  auth0_audience?: string;
  guest_mode?: boolean;
}

export interface ApiError {
  error?: string;
}

export interface ManagementInfo {
  http_addr: string;
  https_addr: string;
  management_addr: string;
  version: string;
  db_path: string | null;
  mode: string;
  http_versions?: string[];
  process_cpu_usage_percent?: number | null;
  process_memory_bytes?: number | null;
  /** Absolute path to loaded pertisk_eproxy_tls_cert_info.beam (debug stale-code issues). */
  loaded_tls_cert_info_beam?: string;
}

export interface RealtimeSnapshot {
  stats: Metrics;
  management: ManagementInfo;
  logs: LogEntry[];
  certificates: CertificateRow[];
}

export interface CertificateRow {
  id: string;
  /** Primary CN / first SAN for display */
  domain?: string;
  hosts: string[];
  issuer?: string;
  challenge?: string;
  source_type: string;
  created_at: string;
  expires_at?: string;
  next_renew?: string;
  /** Site hostnames that reference this certificate id */
  sites?: string[];
}

export interface HelmHistoryEntry {
  revision?: number;
  updated?: string;
  status?: string;
  chart?: string;
  app_version?: string;
  description?: string;
  [key: string]: unknown;
}

export interface HelmHistoryResponse {
  release: string;
  namespace: string;
  history: HelmHistoryEntry[] | Record<string, unknown>;
}

export interface HelmValuesResponse {
  release: string;
  namespace: string;
  revision: number;
  values: string;
}

export type VersionResponse = { version: string };

// ---------------------------------------------------------------------------
// HTTP helper
// ---------------------------------------------------------------------------

async function request<T>(path: string, options: RequestInit = {}): Promise<T> {
  const token = getToken();
  const headers: Record<string, string> = {
    'Content-Type': 'application/json',
    ...(options.headers as Record<string, string>),
  };
  if (token) headers.Authorization = `Bearer ${token}`;

  const res = await fetch(`${API}${path}`, {
    ...options,
    headers,
    credentials: 'include',
  });

  if (res.status === 401) {
    clearToken();
    clearUsername();
    if (!window.location.pathname.startsWith('/login')) {
      window.location.href = '/login';
    }
    throw new Error('Unauthorized');
  }

  if (!res.ok) {
    let msg = res.statusText;
    try {
      const j = (await res.json()) as ApiError;
      msg = (j.error as string) ?? msg;
    } catch {
      /* ignore */
    }
    throw new Error(`${res.status}: ${msg}`);
  }

  const ct = res.headers.get('content-type') ?? '';
  if (ct.includes('application/json')) return res.json() as Promise<T>;
  return res.text() as unknown as T;
}

async function get<T>(path: string): Promise<T> {
  /* Avoid stale /api/config (and other GETs) after PUT — browsers may reuse cache for same URL. */
  return request<T>(path, { cache: 'no-store' });
}

async function post<T>(path: string, body: unknown): Promise<T> {
  return request<T>(path, { method: 'POST', body: JSON.stringify(body) });
}

async function put<T>(path: string, body: unknown): Promise<T> {
  return request<T>(path, { method: 'PUT', body: JSON.stringify(body) });
}

async function del<T>(path: string): Promise<T> {
  return request<T>(path, { method: 'DELETE' });
}

export function openRealtimeStream(
  onMessage: (snapshot: RealtimeSnapshot) => void,
  onError?: (event: Event) => void
): () => void {
  const proto = window.location.protocol === 'https:' ? 'wss' : 'ws';
  const baseUrl = new URL(`${proto}://${window.location.host}${API}/realtime`);
  let ws: WebSocket | null = null;
  let closedManually = false;
  let reconnectTimer: number | null = null;
  let reconnectAttempt = 0;

  function reconnectDelayMs(attempt: number): number {
    const base = Math.min(30000, 1000 * Math.pow(2, attempt));
    const jitter = Math.floor(Math.random() * 300);
    return base + jitter;
  }

  function clearReconnectTimer() {
    if (reconnectTimer !== null) {
      window.clearTimeout(reconnectTimer);
      reconnectTimer = null;
    }
  }

  function scheduleReconnect() {
    if (closedManually) return;
    clearReconnectTimer();
    const delay = reconnectDelayMs(reconnectAttempt);
    console.debug('[realtime-ws] scheduling reconnect', { attempt: reconnectAttempt + 1, delay_ms: delay });
    reconnectAttempt += 1;
    reconnectTimer = window.setTimeout(connect, delay);
  }

  function connect() {
    if (closedManually) return;
    const token = getToken();
    const url = new URL(baseUrl.toString());
    if (token) {
      url.searchParams.set('token', token);
    }
    console.debug('[realtime-ws] connecting', { url: url.toString() });
    ws = new WebSocket(url.toString());
    ws.onopen = () => {
      console.info('[realtime-ws] open');
      reconnectAttempt = 0;
    };
    ws.onmessage = (event) => {
      const parseAndDispatch = (raw: string) => {
        try {
          const parsed = JSON.parse(raw) as RealtimeSnapshot;
          const logsLen = Array.isArray(parsed.logs) ? parsed.logs.length : -1;
          console.debug('[realtime-ws] message', { logs: logsLen });
          onMessage(parsed);
        } catch {
          console.error('[realtime-ws] message parse failed');
          // ignore malformed frames
        }
      };

      if (typeof event.data === 'string') {
        parseAndDispatch(event.data);
        return;
      }

      if (event.data instanceof Blob) {
        void event.data.text().then(parseAndDispatch).catch(() => {
          console.error('[realtime-ws] blob decode failed');
        });
        return;
      }

      if (event.data instanceof ArrayBuffer) {
        try {
          const raw = new TextDecoder().decode(event.data);
          parseAndDispatch(raw);
        } catch {
          console.error('[realtime-ws] arraybuffer decode failed');
        }
        return;
      }

      console.error('[realtime-ws] unsupported message type', typeof event.data);
    };
    ws.onerror = (event) => {
      console.error('[realtime-ws] error event', event);
      if (onError) onError(event);
    };
    ws.onclose = (event) => {
      console.warn('[realtime-ws] close', { code: event.code, reason: event.reason, wasClean: event.wasClean });
      ws = null;
      scheduleReconnect();
    };
  }

  connect();
  return () => {
    closedManually = true;
    clearReconnectTimer();
    console.info('[realtime-ws] manual close');
    try {
      ws?.close();
    } catch {
      // ignore
    }
  };
}

function ensureDnsProviderRows(value: unknown): DnsProviderRow[] {
  if (Array.isArray(value)) return value as DnsProviderRow[];
  throw new Error('DNS providers API is unavailable. Restart proxy to load latest backend routes.');
}

// ---------------------------------------------------------------------------
// API surface
// ---------------------------------------------------------------------------

export const api = {
  health: () => get<HealthReport>('/health'),
  version: () => get<VersionResponse>('/version'),
  metrics: () => get<Metrics>('/stats'),
  management: () => get<ManagementInfo>('/management'),
  logs: (params?: { type?: 'system' | 'proxy' | 'all'; host?: string }) => {
    const search = new URLSearchParams();
    if (params?.type && params.type !== 'all') search.set('type', params.type);
    if (params?.host?.trim()) search.set('host', params.host.trim());
    const q = search.toString();
    return get<LogEntry[]>(q ? `/logs?${q}` : '/logs');
  },

  config: () => get<ProxyConfig>('/config'),
  putConfig: (c: ProxyConfig) => put<{ status: string }>('/config', c),

  sites: () => get<Site[]>('/sites'),
  site: (host: string) => get<Site>(`/sites/${encodeURIComponent(host)}`),
  addSite: (s: Site) => post<Site>('/sites', s),
  updateSite: (host: string, s: Site) => put<Site>(`/sites/${encodeURIComponent(host)}`, s),
  deleteSite: (host: string) => del<{ status: string }>(`/sites/${encodeURIComponent(host)}`),

  backends: () => get<Backend[]>('/backends'),
  addBackend: (b: Backend) => post<Backend>('/backends', b),
  backendStatus: (name: string) => get<BackendStatus>(`/backends/${encodeURIComponent(name)}`),
  deleteBackend: (name: string) => del<{ status: string }>(`/backends/${encodeURIComponent(name)}`),

  metricsText: () => request<string>('/metrics'),

  reload: () => post<{ status: string }>('/reload', {}),

  login: (username: string, password: string) =>
    post<LoginResponse>('/auth/login', { username, password }),
  authConfig: () => get<AuthConfigResponse>('/auth/config'),
  authRefresh: () => post<AuthRefreshResponse>('/auth/refresh', {}),
  authCheck: () => get<AuthCheckResponse>('/auth/check'),
  logout: () => post<{ success: boolean }>('/auth/logout', {}),
  changePassword: (currentPassword: string, newPassword: string) =>
    post<{ success: boolean }>('/admin/change-password', {
      current_password: currentPassword,
      new_password: newPassword,
    }),

  apiToken: {
    get: () => get<{ has_token: boolean }>('/admin/api-token'),
    create: () => post<{ token: string; message: string }>('/admin/api-token', {}),
  },

  helmHistory: () => get<HelmHistoryResponse>('/helm/history'),
  helmValues: (revision: number) => get<HelmValuesResponse>(`/helm/values/${revision}`),

  certificates: {
    list: () => get<CertificateRow[]>('/certificates'),
    importPem: (cert_pem: string, key_pem: string) =>
      post<{ status: string; id: number; notice?: string }>('/certificates/import', {
        cert_pem,
        key_pem,
      }),
    updatePem: (id: string, cert_pem: string, key_pem: string) =>
      put<{ status: string; notice?: string }>(`/certificates/${encodeURIComponent(id)}/import`, {
        cert_pem,
        key_pem,
      }),
    createLabel: async (id: string) => {
      const n = id.trim();
      if (!n) throw new Error('Certificate id is required');
      await post<{ status: string; id: number }>('/certificates', { name: n });
    },
    updateLabel: async (prevId: string, nextId: string) => {
      const from = prevId.trim();
      const to = nextId.trim();
      if (!from) throw new Error('Certificate id is required');
      if (!to) throw new Error('Certificate name is required');
      await put<{ status: string }>(`/certificates/${encodeURIComponent(from)}`, { name: to });
    },
    deleteLabel: async (id: string) => {
      const n = id.trim();
      if (!n) throw new Error('Certificate id is required');
      await del<{ status: string }>(`/certificates/${encodeURIComponent(n)}`);
    },
    importListenerPem: (cert_pem: string, key_pem: string) =>
      post<{ status: string; tls_cert_file: string; tls_key_file: string; notice?: string }>('/tls/listener', {
        cert_pem,
        key_pem,
      }),
    deleteListenerTls: async () => {
      const c = await get<ProxyConfig>('/config');
      const merged = prepareConfigForPut({
        ...c,
        tls_cert_file: null,
        tls_key_file: null,
      });
      await put<{ status: string }>('/config', merged);
    },
    upload: (_body: { hosts: string[]; cert_pem: string; key_pem: string }) =>
      Promise.reject(new Error('Use certificates.importListenerPem for the listener TLS PEM.')),
    delete: (_id: string) => Promise.reject(new Error('Certificate delete is not implemented for eProxy')),
    renew: (_id: string) => Promise.reject(new Error('Certificate renew is not implemented for eProxy')),
    renewStatus: (_id: string) => Promise.reject(new Error('Certificate renew is not implemented for eProxy')),
  },

  dnsProviders: {
    list: async () => ensureDnsProviderRows(await get<unknown>('/dns-providers')),
    supported: async () => SUPPORTED_DNS_PROVIDERS as SupportedDnsProvider[],
    create: async (name: string, provider_type: DnsProviderType, credentials?: Record<string, string> | null) => {
      const n = name.trim();
      if (!n) throw new Error('Name is required');
      const pt = (provider_type || DNS_LABEL_PROVIDER_ID).trim() || DNS_LABEL_PROVIDER_ID;
      const creds = credentials && typeof credentials === 'object' ? { ...credentials } : {};
      await post<{ status: string; id: string }>('/dns-providers', { name: n, provider_type: pt, credentials: creds });
      return ensureDnsProviderRows(await get<unknown>('/dns-providers'));
    },
    get: async (id: string) => {
      const rows = ensureDnsProviderRows(await get<unknown>('/dns-providers'));
      const row = rows.find((r) => String(r.id) === String(id));
      if (!row) throw new Error('DNS provider not found');
      return row;
    },
    put: async (id: string, name: string, provider_type: DnsProviderType, credentials?: Record<string, string> | null) => {
      const n = name.trim();
      if (!n) throw new Error('Name is required');
      const pt = (provider_type || DNS_LABEL_PROVIDER_ID).trim() || DNS_LABEL_PROVIDER_ID;
      const creds = credentials && typeof credentials === 'object' ? { ...credentials } : {};
      await put<{ status: string }>(`/dns-providers/${encodeURIComponent(id)}`, {
        name: n,
        provider_type: pt,
        credentials: creds,
      });
      return ensureDnsProviderRows(await get<unknown>('/dns-providers'));
    },
    delete: async (id: string) => {
      await del<{ status: string }>(`/dns-providers/${encodeURIComponent(id)}`);
      return ensureDnsProviderRows(await get<unknown>('/dns-providers'));
    },
  },

  kubernetes: {
    namespaces: () => Promise.reject(new Error('Kubernetes is not available on eProxy')),
    pods: () => Promise.reject(new Error('Kubernetes is not available on eProxy')),
    deployments: () => Promise.reject(new Error('Kubernetes is not available on eProxy')),
    services: () => Promise.reject(new Error('Kubernetes is not available on eProxy')),
    configmaps: () => Promise.reject(new Error('Kubernetes is not available on eProxy')),
    secrets: () => Promise.reject(new Error('Kubernetes is not available on eProxy')),
    tlsSecrets: () => Promise.reject(new Error('Kubernetes is not available on eProxy')),
    ingresses: () => Promise.reject(new Error('Kubernetes is not available on eProxy')),
    createIngress: () => Promise.reject(new Error('Kubernetes is not available on eProxy')),
    getIngress: () => Promise.reject(new Error('Kubernetes is not available on eProxy')),
    updateIngress: () => Promise.reject(new Error('Kubernetes is not available on eProxy')),
    deleteIngress: () => Promise.reject(new Error('Kubernetes is not available on eProxy')),
    nodes: () => Promise.reject(new Error('Kubernetes is not available on eProxy')),
    events: () => Promise.reject(new Error('Kubernetes is not available on eProxy')),
    clusterSummary: () => Promise.reject(new Error('Kubernetes is not available on eProxy')),
  },
};
