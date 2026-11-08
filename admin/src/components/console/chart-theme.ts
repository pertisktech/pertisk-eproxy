import type { CSSProperties } from 'react';

/** Shared Recharts styling driven by eproxy CSS variables. */
export const chartColors = {
  c1: 'var(--color-chart-1)',
  c2: 'var(--color-chart-2)',
  c3: 'var(--color-chart-3)',
  c4: 'var(--color-chart-4)',
  c5: 'var(--color-chart-5)',
  grid: 'var(--color-border)',
  muted: 'var(--color-muted-foreground)',
} as const;

export const chartAxisProps = {
  stroke: 'var(--color-muted-foreground)',
  fontSize: 11,
  tickLine: false,
  axisLine: false,
} as const;

export const chartGridProps = {
  strokeDasharray: '3 3',
  stroke: 'var(--color-border)',
  vertical: false,
} as const;

export const chartMargin = { left: -8, right: 8, top: 8, bottom: 0 } as const;

export const chartTooltipContentStyle: CSSProperties = {
  background: 'var(--color-popover)',
  border: '1px solid var(--color-border)',
  borderRadius: 8,
  fontSize: 12,
  color: 'var(--color-popover-foreground)',
  boxShadow: 'var(--shadow-md)',
};

export const chartTooltipLabelStyle: CSSProperties = { color: 'var(--color-muted-foreground)' };
export const chartTooltipItemStyle: CSSProperties = { color: 'var(--color-popover-foreground)' };

export const protocolColors = {
  http: 'var(--color-chart-5)',
  https: 'var(--color-chart-3)',
  grpc: 'var(--color-chart-4)',
  h2: 'var(--color-chart-2)',
  h3: 'var(--color-chart-1)',
} as const;

/** Linear gradient fill stops for Area charts (use inside <defs>). */
export function areaGradientStops(color: string, topOpacity = 0.35) {
  return [
    { offset: '0%', color, opacity: topOpacity },
    { offset: '100%', color, opacity: 0 },
  ];
}

export function formatChartAxisTimeMs(ms: number): string {
  if (!Number.isFinite(ms)) return '';
  const d = new Date(ms);
  const pad = (n: number) => String(n).padStart(2, '0');
  return `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
}

export function formatChartTooltipXLabel(label: unknown): string {
  if (typeof label === 'number' && Number.isFinite(label)) return formatChartAxisTimeMs(label);
  if (typeof label === 'string' && /^\d+$/.test(label.trim())) return formatChartAxisTimeMs(Number(label));
  return label == null ? '' : String(label);
}

export function formatChartNumber(v: number): string {
  if (!Number.isFinite(v)) return '';
  if (Math.abs(v) >= 1000) return new Intl.NumberFormat(undefined, { maximumFractionDigits: 0 }).format(v);
  if (Number.isInteger(v)) return String(v);
  return v.toFixed(2);
}
