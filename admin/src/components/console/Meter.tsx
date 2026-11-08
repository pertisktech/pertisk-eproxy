import type { ReactNode } from 'react';
import styles from './Meter.module.css';

function clampPercent(value: number) {
  if (!Number.isFinite(value)) return 0;
  return Math.min(100, Math.max(0, value));
}

export function Meter({
  label,
  detail,
  pct,
  icon,
  title,
}: {
  label: string;
  detail: string;
  /** 0–100. When null the bar track is hidden (value unknown or has no natural ceiling). */
  pct: number | null;
  icon?: ReactNode;
  title?: string;
}) {
  return (
    <div className={styles.meter} title={title}>
      <div className={styles.row}>
        <span className={styles.label}>
          {icon ? <span className={styles.icon}>{icon}</span> : null}
          {label}
        </span>
        <span className={styles.detail}>{detail}</span>
      </div>
      {pct != null ? (
        <div className={styles.track} role="progressbar" aria-valuemin={0} aria-valuemax={100} aria-valuenow={Math.round(clampPercent(pct))} aria-label={label}>
          <div className={styles.fill} style={{ width: `${clampPercent(pct)}%` }} />
        </div>
      ) : null}
    </div>
  );
}
