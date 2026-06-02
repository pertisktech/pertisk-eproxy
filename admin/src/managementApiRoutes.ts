/**
 * Management REST/WebSocket routes — keep in sync with README.md § “Management API”.
 * (Docs page renders this list.)
 */
export interface ManagementApiRouteRow {
  method: string;
  path: string;
  purpose: string;
}

export const MANAGEMENT_API_ROUTES: readonly ManagementApiRouteRow[] = [
  { method: 'GET', path: '/api/version', purpose: 'Application version' },
  { method: 'HEAD', path: '/api/version', purpose: 'Same as GET (no JSON body); Chrome HTTP/3 probe' },
  {
    method: 'GET',
    path: '/api/proto',
    purpose: 'Protocol/debug snapshot (request scheme/protocol details and headers)',
  },
  {
    method: 'GET',
    path: '/api/management',
    purpose:
      'Node, listeners, config_file (on-disk JSON path), process_info, CPU/memory, runtime capabilities, optional public IP snapshot',
  },
  {
    method: 'GET',
    path: '/api/stats',
    purpose:
      'Counters for the admin UI (requests by protocol, bytes, connections, log buffer size, uptime, per-site maps, …)',
  },
  {
    method: 'GET',
    path: '/api/realtime',
    purpose: 'WebSocket — live snapshots (stats, management, logs, certificates, SSL jobs)',
  },
  { method: 'GET', path: '/api/logs', purpose: 'Access log ring; optional query type, host, site' },
  { method: 'GET', path: '/api/auth/config', purpose: 'Auth mode and login-related fields' },
  { method: 'HEAD', path: '/api/auth/config', purpose: 'Same as GET (no JSON body)' },
  { method: 'POST', path: '/api/auth/login', purpose: 'Obtain session token (local auth)' },
  { method: 'POST', path: '/api/auth/refresh', purpose: 'Refresh session token' },
  { method: 'GET', path: '/api/auth/check', purpose: 'Whether the current session is authenticated' },
  { method: 'POST', path: '/api/auth/logout', purpose: 'End session' },
  {
    method: 'POST',
    path: '/api/admin/change-password',
    purpose: 'Password change (not implemented; returns 501)',
  },
  { method: 'GET', path: '/api/admin/api-token', purpose: 'API token status (stub)' },
  { method: 'POST', path: '/api/admin/api-token', purpose: 'API token (stub)' },
  { method: 'GET', path: '/api/backup/export', purpose: 'Download config backup' },
  { method: 'POST', path: '/api/backup/restore', purpose: 'Upload and restore config from backup' },
  { method: 'GET', path: '/api/helm/history', purpose: 'Helm history (stub for non-K8s deployments)' },
  { method: 'GET', path: '/api/helm/values/:revision', purpose: 'Helm values for revision (stub)' },
  { method: 'GET', path: '/api/certificates', purpose: 'List stored TLS certificates' },
  { method: 'POST', path: '/api/certificates', purpose: 'Create certificate metadata row' },
  { method: 'POST', path: '/api/certificates/import', purpose: 'Import PEM bundle (new or update)' },
  {
    method: 'PUT',
    path: '/api/certificates/:id/import',
    purpose: 'Import PEM for existing certificate id',
  },
  { method: 'PUT', path: '/api/certificates/:id', purpose: 'Update certificate row' },
  { method: 'DELETE', path: '/api/certificates/:id', purpose: 'Delete certificate row' },
  { method: 'GET', path: '/api/dns-providers', purpose: 'List DNS providers (e.g. ACME DNS-01)' },
  { method: 'POST', path: '/api/dns-providers', purpose: 'Create DNS provider' },
  {
    method: 'POST',
    path: '/api/dns-providers/validate',
    purpose: 'Validate DNS provider credentials/configuration',
  },
  { method: 'PUT', path: '/api/dns-providers/:id', purpose: 'Update DNS provider' },
  { method: 'DELETE', path: '/api/dns-providers/:id', purpose: 'Delete DNS provider' },
  {
    method: 'POST',
    path: '/api/tls/listener',
    purpose:
      'Set tls_cert_file / tls_key_file on in-memory config (see response notice for HTTPS reload)',
  },
  { method: 'GET', path: '/api/config', purpose: 'Full proxy configuration JSON' },
  { method: 'PUT', path: '/api/config', purpose: 'Replace full configuration (hot reload)' },
  { method: 'GET', path: '/api/sites', purpose: 'List sites' },
  { method: 'POST', path: '/api/sites', purpose: 'Add site' },
  { method: 'GET', path: '/api/sites/:host', purpose: 'Get one site by hostname' },
  { method: 'PUT', path: '/api/sites/:host', purpose: 'Replace site' },
  { method: 'DELETE', path: '/api/sites/:host', purpose: 'Remove site' },
  { method: 'GET', path: '/api/backends', purpose: 'List backends' },
  { method: 'POST', path: '/api/backends', purpose: 'Add backend' },
  {
    method: 'GET',
    path: '/api/backends/:name',
    purpose: 'Backend definition and live upstream health',
  },
  { method: 'DELETE', path: '/api/backends/:name', purpose: 'Remove backend' },
  { method: 'GET', path: '/api/health', purpose: 'Aggregated health' },
  { method: 'GET', path: '/api/metrics', purpose: 'Prometheus metrics (text exposition)' },
  { method: 'POST', path: '/api/reload', purpose: 'Reload configuration from the on-disk config file' },
  { method: 'GET', path: '/api/ingress/live', purpose: 'Ingress liveness probe' },
  { method: 'HEAD', path: '/api/ingress/live', purpose: 'Same as GET (no JSON body)' },
  { method: 'GET', path: '/api/ingress/ready', purpose: 'Ingress readiness probe' },
  { method: 'HEAD', path: '/api/ingress/ready', purpose: 'Same as GET (no JSON body)' },
  { method: 'GET', path: '/api/ingress/status', purpose: 'Ingress controller status snapshot' },
  { method: 'HEAD', path: '/api/ingress/status', purpose: 'Same as GET (no JSON body)' },
  { method: 'GET', path: '/api/ingress/watchers', purpose: 'Watcher and leader state' },
  { method: 'GET', path: '/api/ingress/errors', purpose: 'Last ingress reconciliation error' },
  {
    method: 'GET',
    path: '/api/ingress/resources',
    purpose: 'Effective sites/backends synthesized by ingress reconciliation',
  },
  { method: 'GET', path: '/api/kubernetes/namespaces', purpose: 'List Kubernetes namespaces' },
  { method: 'GET', path: '/api/kubernetes/pods', purpose: 'List Kubernetes pods (optional query: namespace)' },
  {
    method: 'GET',
    path: '/api/kubernetes/services',
    purpose: 'List Kubernetes services (optional query: namespace)',
  },
  {
    method: 'GET',
    path: '/api/kubernetes/tls-secrets',
    purpose: 'List Kubernetes TLS secrets (optional query: namespace)',
  },
  { method: 'GET', path: '/api/kubernetes/ingresses', purpose: 'List Kubernetes ingress resources' },
  { method: 'POST', path: '/api/kubernetes/ingresses', purpose: 'Create Kubernetes ingress resource' },
  {
    method: 'GET',
    path: '/api/kubernetes/ingresses/:namespace/:name',
    purpose: 'Get one Kubernetes ingress resource',
  },
  {
    method: 'PUT',
    path: '/api/kubernetes/ingresses/:namespace/:name',
    purpose: 'Update one Kubernetes ingress resource',
  },
  {
    method: 'DELETE',
    path: '/api/kubernetes/ingresses/:namespace/:name',
    purpose: 'Delete one Kubernetes ingress resource',
  },
];
