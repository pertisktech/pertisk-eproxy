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

function certHostMatchesTarget(certHost: string, targetHost: string): boolean {
  const cert = certHost.trim().toLowerCase();
  const target = targetHost.trim().toLowerCase();
  if (!cert || !target) return false;
  if (cert === target) return true;
  if (!cert.startsWith('*.')) return false;

  const suffix = cert.slice(2);
  if (!suffix || !target.endsWith(`.${suffix}`)) return false;

  const left = target.slice(0, -(suffix.length + 1));
  return left.length > 0 && !left.includes('.');
}

function certificateCoversHost(cert: CertificateRow, host: string): boolean {
  const certHosts = Array.isArray(cert.hosts) ? cert.hosts : [];
  if (certHosts.length === 0) return true;
  const target = hostForTlsValidation(host);
  return certHosts.some((h) => certHostMatchesTarget(h, target));
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

  const cert = certs.find((c) => c.id === certRef);
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

/** Prefer /api/health tls_sites; fill gaps from config sites + certificate list. */
export function buildTlsSiteValidationRows(
  sites: Site[],
  health: HealthReport | null | undefined,
  certs: CertificateRow[],
): TlsSiteValidationRow[] {
  const healthByHost = new Map<string, TlsSiteValidationRow>();
  for (const row of health?.tls_sites ?? []) {
    const normalized = normalizeHealthRow(row);
    if (normalized) {
      healthByHost.set(normalized.host.toLowerCase(), normalized);
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

    rows.push(healthByHost.get(key) ?? buildRowFromSite(site, certs));
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
