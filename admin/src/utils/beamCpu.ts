/**
 * BEAM management CPU: scheduler runtime ÷ wall clock between samples (`process_cpu_usage_percent`).
 * This is **not** “percent of all host CPUs”. Rough average CPU cores used by the VM ≈ percent ÷ 100.
 * Values above 100% can appear on multi-core when several schedulers are busy in one interval.
 */

export function beamCpuEquivalentCores(pct: number): number {
  return pct / 100;
}

/** Share of all logical CPUs on the host (0–100+, can exceed 100 if BEAM metric > 100 × processors). */
export function beamCpuShareOfHostCpusPercent(pct: number, logicalProcessors: number): number {
  if (!logicalProcessors || logicalProcessors < 1) return 0;
  return (beamCpuEquivalentCores(pct) / logicalProcessors) * 100;
}

export function formatBeamCpuPct(pct: number): string {
  return `${pct.toFixed(1)}%`;
}

/**
 * Primary UI copy: cores average vs host, easier to read than raw BEAM % + millicores.
 */
export function formatPertiskVmCpuLine(pct: number, logicalProcessors?: number | null): string {
  const eq = beamCpuEquivalentCores(pct);
  const eqStr = Math.abs(eq) >= 10 ? eq.toFixed(1) : eq.toFixed(2);
  if (logicalProcessors != null && logicalProcessors > 0) {
    const hostPct = beamCpuShareOfHostCpusPercent(pct, logicalProcessors);
    const hostStr =
      hostPct < 0.01 ? hostPct.toFixed(4) : hostPct < 1 ? hostPct.toFixed(2) : hostPct.toFixed(1);
    return `~${eqStr} cores (${hostStr}% of ${logicalProcessors} CPUs)`;
  }
  return `~${eqStr} cores avg`;
}

/** Short tooltip: explains the raw scheduler metric. */
export function pertiskVmCpuTooltip(logicalProcessors?: number | null): string {
  const base =
    'Average CPU used by the Erlang VM in the last sample: scheduler runtime ÷ wall time. ' +
    'That percentage is not “% of all cores”; we show ~cores and % of host logical CPUs when known.';
  if (logicalProcessors != null && logicalProcessors > 0) {
    return `${base} This host reports ${logicalProcessors} logical CPUs.`;
  }
  return base;
}
