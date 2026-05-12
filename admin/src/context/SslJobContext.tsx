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

export type SslJobContextValue = {
  jobsByHost: Record<string, SslJobRow>;
  lastPush: SslJobPush | null;
  mergeFromSnapshot: (rows: unknown) => void;
  applySslJobPush: (ev: SslJobPush) => void;
};

export type SslJobActionsValue = Pick<SslJobContextValue, 'mergeFromSnapshot' | 'applySslJobPush'>;

const SslJobActionsContext = createContext<SslJobActionsValue | null>(null);
const SslJobJobsContext = createContext<Record<string, SslJobRow>>({});
const SslJobLastPushContext = createContext<SslJobPush | null>(null);

export function SslJobProvider({ children }: { children: ReactNode }) {
  const [jobsByHost, setJobsByHost] = useState<Record<string, SslJobRow>>({});
  const [lastPush, setLastPush] = useState<SslJobPush | null>(null);

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
    setLastPush(ev);
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

  const actions = useMemo(
    () => ({ mergeFromSnapshot, applySslJobPush }),
    [mergeFromSnapshot, applySslJobPush]
  );

  return (
    <SslJobActionsContext.Provider value={actions}>
      <SslJobJobsContext.Provider value={jobsByHost}>
        <SslJobLastPushContext.Provider value={lastPush}>{children}</SslJobLastPushContext.Provider>
      </SslJobJobsContext.Provider>
    </SslJobActionsContext.Provider>
  );
}

/** Stable actions only — Layout shell can subscribe without re-rendering on every SSL job snapshot. */
export function useSslJobActions(): SslJobActionsValue {
  const ctx = useContext(SslJobActionsContext);
  if (!ctx) {
    throw new Error('useSslJobActions must be used within SslJobProvider');
  }
  return ctx;
}

export function useSslJobs(): SslJobContextValue {
  const jobsByHost = useContext(SslJobJobsContext);
  const lastPush = useContext(SslJobLastPushContext);
  const { mergeFromSnapshot, applySslJobPush } = useSslJobActions();
  return useMemo(
    () => ({ jobsByHost, lastPush, mergeFromSnapshot, applySslJobPush }),
    [jobsByHost, lastPush, mergeFromSnapshot, applySslJobPush]
  );
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
