import { clearToken, clearUsername, getToken } from '@/auth';
import { SUPPORTED_DNS_PROVIDERS } from './supportedDnsProviders';

export type {
  SupportedDnsProviderDef as SupportedDnsProvider,
  SupportedDnsFieldDef as SupportedDnsProviderField,
} from './supportedDnsProviders';

const API = '/api';

function isLocalRealtimeLogEnabled(): boolean {
  if (import.meta.env.DEV) return true;
  const host = globalThis.window.location.hostname;
  return host === 'localhost' || host === '127.0.0.1' || host === '::1';
}

const REALTIME_LOG_ENABLED = isLocalRealtimeLogEnabled();

function realtimeLog(level: 'debug' | 'info' | 'warn' | 'error', ...args: unknown[]): void {
  if (!REALTIME_LOG_ENABLED) return;
  // Keep realtime transport logs available only for local/dev troubleshooting.
  if (level === 'debug') console.debug(...args);
  else if (level === 'info') console.info(...args);
  else if (level === 'warn') console.warn(...args);
  else console.error(...args);
}

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
  acme_wildcard_base?: string | null;
  advertise_http3?: boolean | null;
  acme_contact_email?: string | null;
  /** Set in ingress mode when reconciled from a Kubernetes Ingress. */
  ingress_namespace?: string | null;
  ingress_name?: string | null;
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
  /** Runtime mode from config (management API echoes the same strings). */
  mode: 'proxy' | 'ingress';
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

function asPlainString(value: unknown): string {
  if (typeof value === 'string') return value;
  if (typeof value === 'number' || typeof value === 'boolean' || typeof value === 'bigint') {
    return String(value);
  }
  return '';
}

function asTrimmedPlainString(value: unknown): string {
  return asPlainString(value).trim();
}

function normalizeCredentials(value: unknown): Record<string, string> {
  const credentials: Record<string, string> = {};
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    return credentials;
  }
  for (const [k, v] of Object.entries(value)) {
    const normalized = asPlainString(v);
    if (normalized.length > 0) {
      credentials[k] = normalized;
    }
  }
  return credentials;
}

function normalizeDnsProviderEntry(entry: unknown): DnsProviderConfigEntry {
  if (typeof entry === 'string') {
    const name = entry.trim();
    const provider_type = inferProviderTypeFromLegacy(name, undefined);
    return { name, provider_type, credentials: {} };
  }

  if (!entry || typeof entry !== 'object' || Array.isArray(entry)) {
    return { name: '', provider_type: DNS_LABEL_PROVIDER_ID, credentials: {} };
  }

  const obj = entry as Record<string, unknown>;
  const name = asPlainString(obj.name);
  const explicitPt = asTrimmedPlainString(obj.provider_type);
  const provider_type = inferProviderTypeFromLegacy(name, explicitPt || undefined);
  const credentials = normalizeCredentials(obj.credentials);
  return { name, provider_type, credentials };
}

/** Normalize `dns_providers` from config (legacy strings or objects) for the admin UI. */
export function normalizeDnsProviders(raw: unknown): DnsProviderConfigEntry[] {
  if (!Array.isArray(raw)) return [];
  return raw.map(normalizeDnsProviderEntry);
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
  const tlsCertFile = c.tls_cert_file === '[redacted]' ? null : c.tls_cert_file;
  const tlsKeyFile = c.tls_key_file === '[redacted]' ? null : c.tls_key_file;
  return {
    ...c,
    tls_cert_file: tlsCertFile,
    tls_key_file: tlsKeyFile,
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
  provider_type: string;
  credentials?: Record<string, string> | null;
  created_at: string;
}

export interface DnsProviderDeleteResult {
  ok: boolean;
  rows: DnsProviderRow[];
  reason?: string;
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
  acme?: {
    lego_installed?: boolean;
    lego_path?: string | null;
    lego_required?: boolean;
  };
  tls_sites?: Array<{
    host: string;
    certificate?: string | null;
    certificate_id?: string | null;
    valid: boolean;
    status: 'ok' | 'mismatch' | 'unknown' | 'none' | 'pending';
    reason: string;
    presented_hosts: string[];
  }>;
}

export interface DnsProviderValidateResponse {
  ok: boolean;
  error?: string;
  details?: Record<string, unknown>;
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
  /** Management API JSON responses (proto=admin); included in `http_requests_total` for chart visibility. */
  management_requests_total?: number;
  site_h2_requests_total: Record<string, number>;
  site_h3_requests_total: Record<string, number>;
  site_requests_total?: Record<string, number>;
  site_bytes_received_total?: Record<string, number>;
  site_bytes_sent_total?: Record<string, number>;
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
  site?: string;
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
  /** From proxy config (`proxy` vs `ingress`); served on public GET /api/auth/config for shell after refresh. */
  deployment_mode?: string;
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

export interface ManagementListener {
  id: string;
  description: string;
  protocol: string;
  bind: string;
  port: number;
  tls: boolean;
  stack: string;
}

/** Subset of erlang:memory/0 (bytes per category). */
export interface BeamMemoryBreakdown {
  total?: number;
  processes?: number;
  processes_used?: number;
  system?: number;
  atom?: number;
  binary?: number;
  code?: number;
  ets?: number;
}

export interface ManagementProcessInfo {
  node: string;
  os_pid: string;
  hostname: string;
  otp_release: string;
  erts_version: string;
  system_architecture: string;
  word_size: number;
  schedulers: number;
  logical_processors: number;
  smp_enabled: boolean;
  thread_pool: number;
  process_count: number;
  process_limit: number;
  memory_total_bytes: number;
  memory_breakdown_bytes?: BeamMemoryBreakdown;
  os_type: string;
  os_version: string;
}

export interface ManagementRuntimeCapabilities {
  beam: string;
  jit: boolean;
  cowboy_quic: boolean;
  quicer_application: boolean;
  h3_api_gateway_config: boolean;
  tls_listener_configured: boolean;
  proxy_http3_udp: boolean;
}

export interface ManagementInfo {
  http_addr: string;
  https_addr: string;
  management_addr: string;
  /** On-disk proxy JSON path (`config_file` in sys.config); same file `POST /api/reload` reads. */
  config_file?: string;
  version: string;
  db_path: string | null;
  mode: string;
  leader_election?: {
    enabled: boolean;
    is_leader: boolean;
    namespace: string;
    lease_name: string;
  } | null;
  http_versions?: string[];
  process_cpu_usage_percent?: number | null;
  process_memory_bytes?: number | null;
  /** Absolute path to loaded pertisk_eproxy_tls_cert_info.beam (debug stale-code issues). */
  loaded_tls_cert_info_beam?: string;
  listeners?: ManagementListener[];
  process_info?: ManagementProcessInfo;
  runtime_capabilities?: ManagementRuntimeCapabilities;
  public_ipv4?: string | null;
  public_ipv6?: string | null;
  public_ip_fetched_at_ms?: number | null;
  public_ip_error?: string | null;
}

export interface RealtimeSnapshot {
  stats: Metrics;
  management: ManagementInfo;
  logs: LogEntry[];
  certificates: CertificateRow[];
  /** Active ACME / auto-SSL jobs (from periodic snapshot). */
  ssl_jobs?: SslJobRow[];
}

/** One site’s auto-SSL / ACME progress (snapshot row or WS push). */
export interface SslJobRow {
  host: string;
  phase: string;
  message: string;
  error?: string | null;
  updated_at_ms?: number;
}

/** Immediate WS frame when issuance phase changes. */
export interface SslJobPush {
  type: 'ssl_job';
  host: string;
  phase: string;
  message?: string;
  error?: string | null;
  updated_at_ms?: number;
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

function reconnectDelayMs(attempt: number): number {
  const base = Math.min(30000, 1000 * Math.pow(2, attempt));
  const jitter = Math.floor(Math.random() * 300);
  return base + jitter;
}

function isChromiumBrowser(): boolean {
  if (typeof navigator === 'undefined') return false;
  const ua = navigator.userAgent;
  return /Chrome\//.test(ua) && !/Edg\//.test(ua) && !/OPR\//.test(ua);
}

function preferSseRealtimeForChromium(): boolean {
  return globalThis.window?.location.protocol === 'https:' && isChromiumBrowser();
}

type RealtimeTransportMode = 'auto' | 'sse' | 'ws';

function realtimeTransportMode(): RealtimeTransportMode {
  const env = import.meta.env as { VITE_REALTIME_TRANSPORT?: string };
  const raw = (env.VITE_REALTIME_TRANSPORT ?? '').trim().toLowerCase();
  if (raw === 'sse') return 'sse';
  if (raw === 'ws' || raw === 'websocket') return 'ws';
  return 'auto';
}

const API_REQUEST_TIMEOUT_MS = 90_000;

const RETRYABLE_PATHS = new Set(['/config', '/certificates']);
/** Max retries for GET / safe PUT during transient server unavailability (TLS reload window). */
const MAX_SAFE_RETRIES = 4;
/** Statuses that indicate the server is temporarily unavailable after a listener restart. */
function isTransientStatus(status: number): boolean {
  return status === 408 || status === 502 || status === 503 || status === 504;
}

type ApiRequestOptions = RequestInit & {
  suppressAuthRedirect?: boolean;
};

async function request<T>(path: string, options: ApiRequestOptions = {}): Promise<T> {
  const { suppressAuthRedirect = false, ...fetchOptions } = options;
  const token = getToken();
  const headers: Record<string, string> = {
    'Content-Type': 'application/json',
    ...(fetchOptions.headers as Record<string, string>),
  };
  if (token) {
    headers.Authorization = `Bearer ${token}`;
    /* Some reverse proxies strip Authorization; backend also reads X-Eproxy-Bearer. */
    headers['X-Eproxy-Bearer'] = token;
  }

  const method = String(fetchOptions.method ?? 'GET').toUpperCase();
  const isSafeRetryable =
    method === 'GET' || (method === 'PUT' && RETRYABLE_PATHS.has(path));

  const fetchOnce = async (): Promise<Response> => {
    const controller = new AbortController();
    const timeoutId = window.setTimeout(() => controller.abort(), API_REQUEST_TIMEOUT_MS);
    try {
      return await fetch(`${API}${path}`, {
        ...fetchOptions,
        headers,
        credentials: 'include',
        signal: controller.signal,
      });
    } finally {
      window.clearTimeout(timeoutId);
    }
  };

  const sleep = (ms: number) => new Promise<void>((r) => window.setTimeout(r, ms));

  let res: Response | undefined;
  let lastErr: unknown;
  for (let attempt = 0; attempt <= (isSafeRetryable ? MAX_SAFE_RETRIES : 0); attempt++) {
    if (attempt > 0) {
      // Backoff: 500 ms, 1 s, 2 s, 4 s — covers the proxy TLS listener restart window.
      await sleep(Math.min(4000, 500 * Math.pow(2, attempt - 1)));
    }
    try {
      res = await fetchOnce();
      // Retry on transient server-side statuses (408 from Cowboy idle, 502/503/504 during restart).
      if (isSafeRetryable && isTransientStatus(res.status) && attempt < MAX_SAFE_RETRIES) {
        continue;
      }
      break;
    } catch (err) {
      if (err instanceof Error && err.name === 'AbortError') {
        throw new Error('Request timed out — the server may still be processing; refresh the page.');
      }
      lastErr = err;
      if (!isSafeRetryable) {
        throw err instanceof Error ? err : new Error('Failed to fetch');
      }
      // Network error (ERR_CONNECTION_REFUSED during listener restart): keep retrying.
    }
  }
  if (res == null) {
    throw lastErr instanceof Error ? lastErr : new Error('Failed to fetch');
  }

  if (res.status === 401) {
    if (!suppressAuthRedirect) {
      clearToken();
      clearUsername();
      if (!globalThis.window.location.pathname.startsWith('/login')) {
        globalThis.window.location.href = '/login';
      }
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

async function post<T>(path: string, body: unknown, options: ApiRequestOptions = {}): Promise<T> {
  return request<T>(path, { ...options, method: 'POST', body: JSON.stringify(body) });
}

async function put<T>(path: string, body: unknown): Promise<T> {
  return request<T>(path, { method: 'PUT', body: JSON.stringify(body) });
}

async function del<T>(path: string): Promise<T> {
  return request<T>(path, { method: 'DELETE' });
}

function openRealtimeSse(
  onMessage: (snapshot: RealtimeSnapshot) => void,
  onError?: (event: Event) => void
): () => void {
  const token = getToken();
  const url = new URL(`${API}/realtime-sse`, globalThis.window.location.origin);
  if (token) {
    url.searchParams.set('token', token);
  }
  let source: EventSource | null = null;
  let closedManually = false;

  function connect() {
    if (closedManually) return;
    realtimeLog('debug', '[realtime-sse] connecting', { url: url.toString() });
    source = new EventSource(url.toString());
    source.addEventListener('snapshot', (event) => {
      try {
        const snap = JSON.parse((event as MessageEvent<string>).data) as RealtimeSnapshot;
        const logsLen = Array.isArray(snap.logs) ? snap.logs.length : -1;
        realtimeLog('debug', '[realtime-sse] snapshot', { logs: logsLen });
        onMessage(snap);
      } catch {
        realtimeLog('error', '[realtime-sse] snapshot parse failed');
      }
    });
    source.onerror = (event) => {
      realtimeLog('warn', '[realtime-sse] error', event);
      if (onError) onError(event);
      if (!closedManually) {
        source?.close();
        source = null;
        globalThis.window.setTimeout(connect, 3000);
      }
    };
  }

  connect();
  return () => {
    closedManually = true;
    realtimeLog('info', '[realtime-sse] manual close');
    source?.close();
    source = null;
  };
}

function openRealtimeWebSocket(
  onMessage: (snapshot: RealtimeSnapshot) => void,
  onError?: (event: Event) => void,
  onSslJobPush?: (ev: SslJobPush) => void
): () => void {
  /** Optional full WebSocket URL when `/api/realtime` on the page origin is proxied to something other than the management admin WS (e.g. upstream WS on the same path). */
  const env = import.meta.env as { VITE_REALTIME_WEBSOCKET_URL?: string };
  const explicitWs = env.VITE_REALTIME_WEBSOCKET_URL?.trim();
  const baseUrl = explicitWs
    ? new URL(explicitWs)
    : (() => {
        const proto = globalThis.window.location.protocol === 'https:' ? 'wss' : 'ws';
        return new URL(`${proto}://${globalThis.window.location.host}${API}/realtime`);
      })();
  let ws: WebSocket | null = null;
  let closedManually = false;
  let reconnectTimer: number | null = null;
  let reconnectAttempt = 0;

  function clearReconnectTimer() {
    if (reconnectTimer !== null) {
      globalThis.window.clearTimeout(reconnectTimer);
      reconnectTimer = null;
    }
  }

  function scheduleReconnect() {
    if (closedManually) return;
    clearReconnectTimer();
    const delay = reconnectDelayMs(reconnectAttempt);
    realtimeLog('debug', '[realtime-ws] scheduling reconnect', { attempt: reconnectAttempt + 1, delay_ms: delay });
    reconnectAttempt += 1;
    reconnectTimer = globalThis.window.setTimeout(connect, delay);
  }

  function connect() {
    if (closedManually) return;
    const url = new URL(baseUrl.toString());
    realtimeLog('debug', '[realtime-ws] connecting', { url: url.toString() });
    ws = new WebSocket(url.toString());
    ws.onopen = () => {
      realtimeLog('info', '[realtime-ws] open');
      reconnectAttempt = 0;
      const token = getToken();
      if (token) {
        try {
          ws?.send(JSON.stringify({ type: 'auth', token }));
        } catch {
          realtimeLog('error', '[realtime-ws] auth send failed');
        }
      }
    };
    ws.onmessage = (event) => {
      const parseAndDispatch = (raw: string) => {
        try {
          const parsed = JSON.parse(raw) as Record<string, unknown>;
          if (parsed?.type === 'ssl_job') {
            if (onSslJobPush) {
              onSslJobPush(parsed as unknown as SslJobPush);
            }
            return;
          }
          const snap = parsed as unknown as RealtimeSnapshot;
          const logsLen = Array.isArray(snap.logs) ? snap.logs.length : -1;
          realtimeLog('debug', '[realtime-ws] message', { logs: logsLen });
          onMessage(snap);
        } catch {
          realtimeLog('error', '[realtime-ws] message parse failed');
          // ignore malformed frames
        }
      };

      if (typeof event.data === 'string') {
        parseAndDispatch(event.data);
        return;
      }

      if (event.data instanceof Blob) {
        void event.data.text().then(parseAndDispatch).catch(() => {
          realtimeLog('error', '[realtime-ws] blob decode failed');
        });
        return;
      }

      if (event.data instanceof ArrayBuffer) {
        try {
          const raw = new TextDecoder().decode(event.data);
          parseAndDispatch(raw);
        } catch {
          realtimeLog('error', '[realtime-ws] arraybuffer decode failed');
        }
        return;
      }

      realtimeLog('error', '[realtime-ws] unsupported message type', typeof event.data);
    };
    ws.onerror = (event) => {
      realtimeLog('error', '[realtime-ws] error event', event);
      if (onError) onError(event);
    };
    ws.onclose = (event) => {
      realtimeLog('warn', '[realtime-ws] close', { code: event.code, reason: event.reason, wasClean: event.wasClean });
      ws = null;
      const unauthorized = event.code === 4401 || event.code === 1008;
      if (unauthorized) {
        clearToken();
        clearUsername();
        if (!globalThis.window.location.pathname.startsWith('/login')) {
          globalThis.window.location.href = '/login';
        }
        return;
      }
      scheduleReconnect();
    };
  }

  connect();
  return () => {
    closedManually = true;
    clearReconnectTimer();
    realtimeLog('info', '[realtime-ws] manual close');
    try {
      ws?.close();
    } catch {
      // ignore
    }
  };
}

/**
 * Live admin snapshots via WebSocket.
 */
export function openRealtimeStream(
  onMessage: (snapshot: RealtimeSnapshot) => void,
  onError?: (event: Event) => void,
  onSslJobPush?: (ev: SslJobPush) => void
): () => void {
  const mode = realtimeTransportMode();
  // Use SSE only if explicitly configured; default to WebSocket
  const useSse = mode === 'sse';
  if (useSse) {
    return openRealtimeSse(onMessage, onError);
  }
  return openRealtimeWebSocket(onMessage, onError, onSslJobPush);
}

function ensureDnsProviderRows(value: unknown): DnsProviderRow[] {
  if (Array.isArray(value)) return value as DnsProviderRow[];
  throw new Error('DNS providers API is unavailable. Restart proxy to load latest backend routes.');
}

function isHttpStatusError(error: unknown, status: number): boolean {
  if (!(error instanceof Error)) return false;
  return error.message.startsWith(`${status}:`);
}

function normalizeDnsProviderKey(value: unknown): string {
  return String(value ?? '')
    .trim()
    .toLowerCase();
}

async function deleteDnsProviderViaConfigFallback(targetName: string): Promise<boolean> {
  const nameKey = normalizeDnsProviderKey(targetName);
  if (!nameKey) return false;
  const cfg = await get<ProxyConfig>('/config');
  const currentEntries = normalizeDnsProviders(cfg.dns_providers);
  const filtered = currentEntries.filter((entry) => normalizeDnsProviderKey(entry.name) !== nameKey);
  if (filtered.length === currentEntries.length) return false;
  const nextCfg: ProxyConfig = {
    ...cfg,
    dns_providers: dnsProvidersForPut(filtered),
  };
  await put<{ status: string }>('/config', prepareConfigForPut(nextCfg));
  return true;
}

// ---------------------------------------------------------------------------
// API surface
// ---------------------------------------------------------------------------

export const api = {
  health: () => get<HealthReport>('/health'),
  version: () => get<VersionResponse>('/version'),
  metrics: () => get<Metrics>('/stats'),
  management: () => get<ManagementInfo>('/management'),
  logs: (params?: { type?: 'system' | 'proxy' | 'all'; host?: string; site?: string }) => {
    const search = new URLSearchParams();
    if (params?.type && params.type !== 'all') search.set('type', params.type);
    if (params?.host?.trim()) search.set('host', params.host.trim());
    if (params?.site?.trim()) search.set('site', params.site.trim());
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
  /* Refresh can transiently 401 during hot-reload/restart races; caller handles retry. */
  authRefresh: () => post<AuthRefreshResponse>('/auth/refresh', {}, { suppressAuthRedirect: true }),
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
    supported: async () => SUPPORTED_DNS_PROVIDERS,
    create: async (name: string, provider_type: string, credentials?: Record<string, string> | null) => {
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
    put: async (id: string, name: string, provider_type: string, credentials?: Record<string, string> | null) => {
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
    delete: async (id: string): Promise<DnsProviderDeleteResult> => {
      const trimmedId = String(id).trim();
      const rowsBefore = ensureDnsProviderRows(await get<unknown>('/dns-providers'));
      const target = rowsBefore.find((r) => String(r.id) === trimmedId) ?? null;
      const targetNameKey = normalizeDnsProviderKey(target?.name);
      let lastErrorMessage: string | undefined;

      const stillExistsIn = (rows: DnsProviderRow[]): boolean =>
        rows.some((r) => {
          if (String(r.id) === trimmedId) return true;
          if (!targetNameKey) return false;
          return normalizeDnsProviderKey(r.name) === targetNameKey;
        });

      // Prefer config-based deletion to avoid route/version mismatches on DELETE /dns-providers/:id.
      if (target?.name) {
        try {
          const changed = await deleteDnsProviderViaConfigFallback(target.name);
          if (changed) {
            const rowsAfterConfig = ensureDnsProviderRows(await get<unknown>('/dns-providers'));
            return {
              ok: !stillExistsIn(rowsAfterConfig),
              rows: rowsAfterConfig,
              reason: !stillExistsIn(rowsAfterConfig) ? undefined : 'Delete did not remove provider',
            };
          }
        } catch (err) {
          lastErrorMessage = err instanceof Error ? err.message : lastErrorMessage;
        }
      }

      try {
        if (target?.name) {
          await del<{ status: string }>(`/dns-providers/${encodeURIComponent(target.name)}`);
        } else {
          await del<{ status: string }>(`/dns-providers/${encodeURIComponent(trimmedId)}`);
        }
      } catch (err) {
        lastErrorMessage = err instanceof Error ? err.message : 'Delete failed';
        if (isHttpStatusError(err, 404)) {
          try {
            await del<{ status: string }>(`/dns-providers/${encodeURIComponent(trimmedId)}`);
          } catch (err2) {
            lastErrorMessage = err2 instanceof Error ? err2.message : lastErrorMessage;
            const latestRows = ensureDnsProviderRows(await get<unknown>('/dns-providers'));
            const stillExists = stillExistsIn(latestRows);
            if (stillExists) {
              if (target?.name) {
                try {
                  const changed = await deleteDnsProviderViaConfigFallback(target.name);
                  if (changed) {
                    const rowsAfterConfig = ensureDnsProviderRows(await get<unknown>('/dns-providers'));
                    return {
                      ok: !stillExistsIn(rowsAfterConfig),
                      rows: rowsAfterConfig,
                      reason: !stillExistsIn(rowsAfterConfig) ? undefined : lastErrorMessage,
                    };
                  }
                } catch {
                  // keep original delete error below
                }
              }
              return { ok: false, rows: latestRows, reason: lastErrorMessage };
            }
            return { ok: true, rows: latestRows };
          }
        } else {
          const latestRows = ensureDnsProviderRows(await get<unknown>('/dns-providers'));
          return { ok: !stillExistsIn(latestRows), rows: latestRows, reason: lastErrorMessage };
        }
      }
      const rowsAfter = ensureDnsProviderRows(await get<unknown>('/dns-providers'));
      return {
        ok: !stillExistsIn(rowsAfter),
        rows: rowsAfter,
        reason: stillExistsIn(rowsAfter) ? lastErrorMessage ?? 'Delete did not remove provider' : undefined,
      };
    },
    validate: (provider_type: string, credentials?: Record<string, string> | null) => {
      const pt = (provider_type || DNS_LABEL_PROVIDER_ID).trim() || DNS_LABEL_PROVIDER_ID;
      const creds = credentials && typeof credentials === 'object' ? { ...credentials } : {};
      return post<DnsProviderValidateResponse>('/dns-providers/validate', {
        provider_type: pt,
        credentials: creds,
      });
    },
  },

  kubernetes: {
    namespaces: () => get<K8sNamespaceRow[]>('/kubernetes/namespaces'),
    pods: (params?: { namespace?: string }) => {
      const search = new URLSearchParams();
      if (params?.namespace?.trim()) search.set('namespace', params.namespace.trim());
      const q = search.toString();
      return get<K8sPodRow[]>(q ? `/kubernetes/pods?${q}` : '/kubernetes/pods');
    },
    deployments: () => k8sUnavailable('deployments'),
    services: (params?: { namespace?: string }) => {
      const search = new URLSearchParams();
      if (params?.namespace?.trim()) search.set('namespace', params.namespace.trim());
      const q = search.toString();
      return get<K8sServiceRow[]>(q ? `/kubernetes/services?${q}` : '/kubernetes/services');
    },
    configmaps: () => k8sUnavailable('configmaps'),
    secrets: () => k8sUnavailable('secrets'),
    tlsSecrets: (params?: { namespace?: string }) => {
      const search = new URLSearchParams();
      if (params?.namespace?.trim()) search.set('namespace', params.namespace.trim());
      const q = search.toString();
      return get<K8sTlsSecretRow[]>(q ? `/kubernetes/tls-secrets?${q}` : '/kubernetes/tls-secrets');
    },
    ingresses: () => get<K8sIngressListRow[]>('/kubernetes/ingresses'),
    createIngress: (body: CreateIngressBody) =>
      post<CreateIngressResponse>('/kubernetes/ingresses', body),
    getIngress: (namespace: string, name: string) =>
      get<IngressFormRow>(
        `/kubernetes/ingresses/${encodeURIComponent(namespace)}/${encodeURIComponent(name)}`,
      ),
    updateIngress: (namespace: string, name: string, body: CreateIngressBody) =>
      put<CreateIngressResponse>(
        `/kubernetes/ingresses/${encodeURIComponent(namespace)}/${encodeURIComponent(name)}`,
        body,
      ),
    deleteIngress: (namespace: string, name: string) =>
      del<{ message: string; name: string; namespace: string }>(
        `/kubernetes/ingresses/${encodeURIComponent(namespace)}/${encodeURIComponent(name)}`,
      ),
    nodes: () => k8sUnavailable('nodes'),
    events: () => k8sUnavailable('events'),
    clusterSummary: () => k8sUnavailable('cluster summary'),
  },
};

function k8sUnavailable(feature: string): Promise<never> {
  return Promise.reject(new Error(`Kubernetes ${feature} is not available on eProxy`));
}

export interface K8sNamespaceRow {
  name: string;
  created_at: string | null;
}

export interface K8sPodRow {
  name: string;
  namespace: string;
  phase: string;
  node: string | null;
  node_name?: string | null;
  pod_ip?: string | null;
  ready: string;
  restarts?: number | null;
  cpu_usage_millicores?: number | null;
  memory_usage_bytes?: number | null;
  created_at?: string | null;
}

export interface K8sServicePortDetail {
  port: number;
  name?: string | null;
  protocol: string;
}

export interface K8sServiceRow {
  name: string;
  namespace: string;
  type: string;
  cluster_ip: string | null;
  external_ip?: string | null;
  ports: string[];
  ports_detail: K8sServicePortDetail[];
  created_at?: string | null;
}

export interface K8sTlsSecretRow {
  namespace: string;
  name: string;
  issued_at?: string | null;
  expires_at?: string | null;
}

export interface K8sIngressListRow {
  namespace: string;
  name: string;
  host: string;
  ingress_class_name?: string | null;
  tls_secret_name?: string | null;
}

export interface CreateIngressBody {
  name?: string;
  host: string;
  routes?: IngressFormRouteRow[];
  path?: string;
  path_type?: string;
  tls_secret_namespace?: string;
  tls_secret_name?: string;
  service_namespace: string;
  service_name: string;
  service_port?: number;
  service_port_name?: string;
  ingress_namespace?: string;
  ingress_class_name?: string;
}

export interface CreateIngressResponse {
  message: string;
  name: string;
  namespace: string;
}

export interface IngressFormRouteRow {
  path: string;
  path_type: string;
  service_namespace?: string;
  service_name: string;
  service_port?: number | null;
  service_port_name?: string | null;
}

export interface IngressFormRow {
  namespace: string;
  name: string;
  host: string;
  service_namespace: string;
  routes: IngressFormRouteRow[];
  path: string;
  path_type: string;
  tls_secret_namespace?: string | null;
  tls_secret_name?: string | null;
  service_name: string;
  service_port?: number | null;
  service_port_name?: string | null;
  ingress_class_name?: string | null;
}
