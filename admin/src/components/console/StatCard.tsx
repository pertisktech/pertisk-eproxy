import styles from './StatCard.module.css';

export function StatCard({
  label,
  value,
  hint,
  title,
  className,
}: {
  label: string;
  value: string;
  hint?: string | null;
  title?: string;
  className?: string;
}) {
  return (
    <div className={[styles.card, className].filter(Boolean).join(' ')} title={title}>
      <span className={styles.glow} aria-hidden />
      <p className={styles.label}>{label}</p>
      <p className={styles.value}>{value}</p>
      {hint ? <p className={styles.hint}>{hint}</p> : null}
    </div>
  );
}
