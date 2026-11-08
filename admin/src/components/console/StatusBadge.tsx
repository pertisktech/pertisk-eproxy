import type { ReactNode } from 'react';
import { StatusDot, type Tone } from './StatusDot';
import styles from './StatusBadge.module.css';

export function StatusBadge({
  tone,
  children,
  dot = true,
  pulse = false,
  className,
  title,
}: {
  tone: Tone;
  children: ReactNode;
  dot?: boolean;
  pulse?: boolean;
  className?: string;
  title?: string;
}) {
  return (
    <span className={[styles.badge, styles[tone], className].filter(Boolean).join(' ')} title={title}>
      {dot ? <StatusDot tone={tone} pulse={pulse} /> : null}
      {children}
    </span>
  );
}
