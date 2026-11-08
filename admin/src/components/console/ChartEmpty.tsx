import styles from './ChartEmpty.module.css';

export function ChartEmpty({ message, height = 220 }: { message: string; height?: number }) {
  return (
    <div className={styles.empty} style={{ height }}>
      {message}
    </div>
  );
}
