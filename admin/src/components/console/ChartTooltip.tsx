import type { ReactNode } from 'react';
import styles from './ChartTooltip.module.css';

type Entry = {
  name?: string | number;
  value?: number | string;
  color?: string;
  dataKey?: string | number;
  payload?: unknown;
};

/**
 * Custom Recharts tooltip body. Pass as `<Tooltip content={<ChartTooltip ... />} />`.
 * Recharts injects `active`, `payload`, and `label`.
 */
export function ChartTooltip({
  active,
  payload,
  label,
  labelFormatter,
  valueFormatter,
}: {
  active?: boolean;
  payload?: Entry[];
  label?: unknown;
  labelFormatter?: (label: unknown) => ReactNode;
  valueFormatter?: (value: number, name: string) => string;
}) {
  if (!active || !payload || payload.length === 0) return null;
  const heading = labelFormatter ? labelFormatter(label) : label == null ? null : String(label);
  return (
    <div className={styles.tooltip}>
      {heading ? <div className={styles.label}>{heading}</div> : null}
      <ul className={styles.list}>
        {payload.map((p, i) => {
          const name = String(p.name ?? p.dataKey ?? '');
          const raw = typeof p.value === 'number' ? p.value : Number(p.value);
          const text = Number.isFinite(raw)
            ? valueFormatter
              ? valueFormatter(raw, name)
              : raw.toLocaleString()
            : '—';
          return (
            <li key={`${name}-${i}`} className={styles.row}>
              <span className={styles.name}>
                <span
                  className={styles.swatch}
                  style={{ background: p.color ?? (p.payload as { fill?: string } | undefined)?.fill }}
                />
                {name}
              </span>
              <span className={styles.value}>{text}</span>
            </li>
          );
        })}
      </ul>
    </div>
  );
}
