import type { ReactNode } from 'react';
import styles from './Panel.module.css';

export function Panel({
  title,
  description,
  actions,
  children,
  className,
  bodyClassName,
  flush = false,
}: {
  title?: string;
  description?: string;
  actions?: ReactNode;
  children: ReactNode;
  className?: string;
  bodyClassName?: string;
  /** Remove body padding (tables, lists). */
  flush?: boolean;
}) {
  const cls = [styles.panel, className].filter(Boolean).join(' ');
  const bodyCls = [styles.body, flush ? styles.bodyFlush : '', bodyClassName].filter(Boolean).join(' ');
  return (
    <section className={cls}>
      {title || actions ? (
        <header className={styles.header}>
          <div className={styles.headerCopy}>
            {title ? <h2 className={styles.title}>{title}</h2> : null}
            {description ? <p className={styles.description}>{description}</p> : null}
          </div>
          {actions ? <div className={styles.actions}>{actions}</div> : null}
        </header>
      ) : null}
      <div className={bodyCls}>{children}</div>
    </section>
  );
}
