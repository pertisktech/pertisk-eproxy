const API = '/api';

// ---------------------------------------------------------------------------
// Types
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

export interface ProxyConfigRecordSet {
  certificates: string[];
  dns_providers: string[];
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
// HTTP helper
// ---------------------------------------------------------------------------

async function request<T>(path: string, options: RequestInit = {}): Promise<T> {
  const res = await fetch(`${API}${path}`, {
    headers: { 'Content-Type': 'application/json', ...(options.headers as Record<string, string>) },
    ...options,
  });
  if (!res.ok) {
    let msg = res.statusText;
    try { const j = await res.json(); msg = j.error ?? msg; } catch { /* ignore */ }
    throw new Error(`${res.status}: ${msg}`);
  }
  // Some endpoints return plain text (metrics)
  const ct = res.headers.get('content-type') ?? '';
  if (ct.includes('application/json')) return res.json() as Promise<T>;
  return res.text() as unknown as T;
}

// ---------------------------------------------------------------------------
// API surface
// ---------------------------------------------------------------------------

export const api = {
  // Config
  config:      ()               => request<ProxyConfig>('/config'),
  putConfig:   (c: ProxyConfig) => request<{ status: string }>('/config', { method: 'PUT', body: JSON.stringify(c) }),

  // Sites
  sites:       ()               => request<Site[]>('/sites'),
  site:        (host: string)   => request<Site>(`/sites/${encodeURIComponent(host)}`),
  addSite:     (s: Site)        => request<Site>('/sites', { method: 'POST', body: JSON.stringify(s) }),
  updateSite:  (host: string, s: Site) => request<Site>(`/sites/${encodeURIComponent(host)}`, { method: 'PUT', body: JSON.stringify(s) }),
  deleteSite:  (host: string)   => request<{ status: string }>(`/sites/${encodeURIComponent(host)}`, { method: 'DELETE' }),

  // Backends
  backends:    ()               => request<Backend[]>('/backends'),
  addBackend:  (b: Backend)     => request<Backend>('/backends', { method: 'POST', body: JSON.stringify(b) }),
  backendStatus: (name: string) => request<BackendStatus>(`/backends/${encodeURIComponent(name)}`),
  deleteBackend: (name: string) => request<{ status: string }>(`/backends/${encodeURIComponent(name)}`, { method: 'DELETE' }),

  // Health
  health:      ()               => request<HealthReport>('/health'),

  // Metrics (Prometheus text)
  metricsText: ()               => request<string>('/metrics'),

  // Reload
  reload:      ()               => request<{ status: string }>('/reload', { method: 'POST' }),
};
