import { clearToken, clearUsername, getToken } from '@/auth';

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

export interface ProxyConfig {
  mode: 'proxy' | 'proxy_admin';
  http_port: number;
  management_port: number;
  certificates: string[];
  dns_providers: string[];
  sites: Site[];
  backends: Backend[];
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
export type LogEntryType = 'request' | 'response' | 'health_check' | 'config_reload' | 'error' | 'proxy';

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
}

export interface CertificateRow {
  id: string;
  hosts: string[];
  source_type: string;
  created_at: string;
  expires_at?: string;
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
  return request<T>(path);
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
    upload: (_body: { hosts: string[]; cert_pem: string; key_pem: string }) =>
      Promise.reject(new Error('Certificate upload is not implemented for eProxy')),
    delete: (_id: string) => Promise.reject(new Error('Certificate delete is not implemented for eProxy')),
    renew: (_id: string) => Promise.reject(new Error('Certificate renew is not implemented for eProxy')),
    renewStatus: (_id: string) => Promise.reject(new Error('Certificate renew is not implemented for eProxy')),
  },

  dnsProviders: {
    list: async () => {
      const c = await get<ProxyConfig>('/config');
      const names = c.dns_providers ?? [];
      return names.map((name, i) => ({
        id: `name-${i}-${name}`,
        name,
        provider_type: 'custom',
        credentials: null,
        created_at: new Date().toISOString(),
      }));
    },
    supported: () =>
      Promise.resolve(
        [] as {
          id: string;
          name: string;
          fields: { key: string; label: string; type: string; required: boolean }[];
        }[]
      ),
    create: () => Promise.reject(new Error('Use DNS provider names via Sites / config for eProxy')),
    get: () => Promise.reject(new Error('not implemented')),
    put: () => Promise.reject(new Error('not implemented')),
    delete: () => Promise.reject(new Error('not implemented')),
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
