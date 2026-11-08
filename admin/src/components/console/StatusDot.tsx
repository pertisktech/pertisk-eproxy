import styles from './StatusDot.module.css';

export type Tone = 'success' | 'warning' | 'danger' | 'info' | 'muted';

export function StatusDot({
  tone,
  pulse = false,
  className,
}: {
  tone: Tone;
  pulse?: boolean;
  className?: string;
}) {
  return (
    <span className={[styles.dot, styles[tone], className].filter(Boolean).join(' ')} aria-hidden>
      {pulse ? <span className={styles.ping} /> : null}
      <span className={styles.core} />
    </span>
  );
}
