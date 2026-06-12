import type { CertificateRow, HealthReport, Site } from '@/api/client';

export type TlsSiteValidationRow = {
  host: string;
  valid: boolean;
  status: 'ok' | 'mismatch' | 'unknown' | 'none' | 'pending';
  reason: string;
  presented_hosts: string[];
  certificate?: string | null;
};

function hostForTlsValidation(host: string): string {
  const trimmed = host.trim().toLowerCase();
  if (trimmed.startsWith('*.')) {
    const base = trimmed.slice(2);
    return base ? `probe.${base}` : trimmed;
  }
  return trimmed;
}

/** Mirror pertisk_eproxy_admin_handler:cert_pattern_matches_host/3 (single-label wildcard). */
function certHostMatchesTarget(certHost: string, targetHost: string): boolean {
  const host = targetHost.trim().toLowerCase();
  const pattern = certHost.trim().toLowerCase();
  if (!host || !pattern) return false;
  if (host === pattern) return true;
  if (!pattern.startsWith('*.')) return false;

  const suffix = pattern.slice(2);
  if (!suffix) return false;

  const hostParts = host.split('.');
  const suffixParts = suffix.split('.');
  if (hostParts.length !== suffixParts.length + 1) return false;

  return hostParts.slice(1).join('.') === suffixParts.join('.');
}

function certificateCoversHost(cert: CertificateRow, host: string): boolean {
  const certHosts = Array.isArray(cert.hosts) ? cert.hosts : [];
  if (certHosts.length === 0) return true;
  const target = hostForTlsValidation(host);
  return certHosts.some((h) => certHostMatchesTarget(h, target));
}

function hostsEqual(a: string, b: string): boolean {
  return a.trim().toLowerCase() === b.trim().toLowerCase();
}

/**
 * Resolve the certificate row for a site — matches backend find_certificate_row_for_ref
 * plus API `sites` membership (needed when site.certificate is acme/… but DB id is numeric).
 */
function findCertForSite(host: string, certRef: string, certs: CertificateRow[]): CertificateRow | undefined {
  const ref = certRef.trim();
  if (!ref) return undefined;

  const byId = certs.find((c) => c.id === ref || String(c.id) === ref);
  if (byId) return byId;

  const byAssignedSite = certs.find((c) => (c.sites ?? []).some((s) => hostsEqual(s, host)));
  if (byAssignedSite) return byAssignedSite;

  if (ref.startsWith('acme/')) {
    const slug = ref.slice(5);
    const byAcmeRef = certs.find((c) => c.id === ref || hostsEqual(c.domain ?? '', slug));
    if (byAcmeRef) return byAcmeRef;

    const bySlugSan = certs.find((c) => (c.hosts ?? []).some((h) => hostsEqual(h, slug)));
    if (bySlugSan) return bySlugSan;
  }

  const byDomain = certs.find((c) => c.domain === ref);
  if (byDomain) return byDomain;

  return certs.find((c) => certificateCoversHost(c, host));
}

function normalizeHealthRow(row: NonNullable<HealthReport['tls_sites']>[number]): TlsSiteValidationRow | null {
  const host = row.host?.trim();
  if (!host) return null;
  return {
    host,
    valid: row.valid === true,
    status: row.status ?? 'unknown',
    reason: row.reason ?? '',
    presented_hosts: Array.isArray(row.presented_hosts) ? row.presented_hosts : [],
    certificate: row.certificate ?? row.certificate_id ?? null,
  };
}

function buildRowFromSite(site: Site, certs: CertificateRow[]): TlsSiteValidationRow {
  const host = site.host.trim();
  const certRef = site.certificate?.trim() ?? '';

  if (!certRef) {
    return {
      host,
      valid: false,
      status: 'none',
      reason: 'no_certificate_assigned',
      presented_hosts: [],
      certificate: null,
    };
  }

  const cert = findCertForSite(host, certRef, certs);
  if (!cert) {
    return {
      host,
      valid: false,
      status: certRef.startsWith('acme/') ? 'mismatch' : 'unknown',
      reason: 'certificate_not_found',
      presented_hosts: [],
      certificate: certRef,
    };
  }

  const presentedHosts = Array.isArray(cert.hosts) ? cert.hosts : [];
  if (presentedHosts.length === 0) {
    return {
      host,
      valid: false,
      status: 'unknown',
      reason: 'certificate_hosts_unavailable',
      presented_hosts: [],
      certificate: certRef,
    };
  }

  const valid = certificateCoversHost(cert, host);
  return {
    host,
    valid,
    status: valid ? 'ok' : 'mismatch',
    reason: valid ? 'host_covered' : 'certificate_host_mismatch',
    presented_hosts: presentedHosts,
    certificate: certRef,
  };
}

function isFullHealthReport(health: HealthReport | null | undefined): boolean {
  return Array.isArray(health?.tls_sites) || Array.isArray(health?.backends);
}

/** Prefer /api/health tls_sites when the full report is available; otherwise derive from sites + certs. */
export function buildTlsSiteValidationRows(
  sites: Site[],
  health: HealthReport | null | undefined,
  certs: CertificateRow[],
): TlsSiteValidationRow[] {
  const useHealthRows = isFullHealthReport(health);
  const healthByHost = new Map<string, TlsSiteValidationRow>();

  if (useHealthRows) {
    for (const row of health?.tls_sites ?? []) {
      const normalized = normalizeHealthRow(row);
      if (normalized) {
        healthByHost.set(normalized.host.toLowerCase(), normalized);
      }
    }
  }

  const seen = new Set<string>();
  const rows: TlsSiteValidationRow[] = [];

  for (const site of sites) {
    const host = site.host?.trim();
    if (!host) continue;
    const key = host.toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);

    const fromHealth = healthByHost.get(key);
    if (fromHealth) {
      rows.push(fromHealth);
      continue;
    }

    rows.push(buildRowFromSite(site, certs));
  }

  rows.sort((a, b) => a.host.localeCompare(b.host, undefined, { sensitivity: 'base' }));
  return rows;
}

export function tlsValidationResultLabel(row: TlsSiteValidationRow): string {
  if (row.valid) return 'match';
  if (row.status === 'mismatch') return 'mismatch';
  if (row.status === 'pending') return 'pending';
  if (row.status === 'none') return 'none';
  if (row.status === 'ok') return 'match';
  return row.status || 'unknown';
}

export function tlsValidationDetail(row: TlsSiteValidationRow): string {
  if (row.presented_hosts.length > 0) return row.presented_hosts.join(', ');
  return row.reason || '—';
}
