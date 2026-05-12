import { createContext, useCallback, useContext, useMemo, useState, type ReactNode } from 'react';
import type { SslJobRow, SslJobPush } from '@/api/client';

function normalizeRow(r: Partial<SslJobRow> & { host?: string }): SslJobRow {
  return {
    host: String(r.host ?? ''),
    phase: String(r.phase ?? ''),
    message: r.message != null ? String(r.message) : '',
    error: r.error == null || r.error === null ? null : String(r.error),
    updated_at_ms: typeof r.updated_at_ms === 'number' ? r.updated_at_ms : undefined,
  };
}

type SslJobContextValue = {
  jobsByHost: Record<string, SslJobRow>;
  mergeFromSnapshot: (rows: unknown) => void;
  applySslJobPush: (ev: SslJobPush) => void;
};

const SslJobContext = createContext<SslJobContextValue | null>(null);

export function SslJobProvider({ children }: { children: ReactNode }) {
  const [jobsByHost, setJobsByHost] = useState<Record<string, SslJobRow>>({});

  const mergeFromSnapshot = useCallback((rows: unknown) => {
    if (!Array.isArray(rows)) return;
    setJobsByHost(() => {
      const next: Record<string, SslJobRow> = {};
      for (const raw of rows) {
        if (raw && typeof raw === 'object' && 'host' in raw) {
          const r = normalizeRow(raw as Partial<SslJobRow>);
          if (r.host) next[r.host] = r;
        }
      }
      return next;
    });
  }, []);

  const applySslJobPush = useCallback((ev: SslJobPush) => {
    const host = String(ev.host ?? '');
    if (!host) return;
    const phase = String(ev.phase ?? '');
    if (phase === 'idle') {
      setJobsByHost((prev) => {
        if (!(host in prev)) return prev;
        const { [host]: _, ...rest } = prev;
        return rest;
      });
      return;
    }
    const row = normalizeRow({
      host,
      phase,
      message: ev.message,
      error: ev.error,
      updated_at_ms: ev.updated_at_ms,
    });
    setJobsByHost((prev) => ({ ...prev, [host]: row }));
  }, []);

  const value = useMemo(
    () => ({ jobsByHost, mergeFromSnapshot, applySslJobPush }),
    [jobsByHost, mergeFromSnapshot, applySslJobPush]
  );

  return <SslJobContext.Provider value={value}>{children}</SslJobContext.Provider>;
}

export function useSslJobs(): SslJobContextValue {
  const ctx = useContext(SslJobContext);
  if (!ctx) {
    throw new Error('useSslJobs must be used within SslJobProvider');
  }
  return ctx;
}

/** Human-readable ACME phase labels for the admin UI. */
export function formatAcmeSslPhase(phase: string): string {
  const p = phase.trim();
  const labels: Record<string, string> = {
    starting: 'Starting',
    zone: 'DNS zone',
    csr: 'Private key & CSR',
    directory: 'ACME directory',
    account: 'ACME account',
    order: 'Certificate order',
    authorizations: 'Authorizations',
    dns_txt: 'DNS TXT records',
    dns_propagation: 'DNS propagation',
    challenges: 'DNS-01 challenges',
    validation: 'CA validation',
    finalize: 'Finalize',
    certificate: 'Download certificate',
    chain: 'Certificate chain',
    complete: 'Complete',
    error: 'Error',
    idle: 'Idle',
  };
  return labels[p] ?? p;
}
