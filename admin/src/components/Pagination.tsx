import styles from './Pagination.module.css';

type PaginationProps = {
  totalItems: number;
  pageSize: number;
  page: number;
  onPageChange: (nextPage: number) => void;
  ariaLabel?: string;
};

function clamp(n: number, min: number, max: number): number {
  return Math.max(min, Math.min(max, n));
}

export default function Pagination({ totalItems, pageSize, page, onPageChange, ariaLabel }: PaginationProps) {
  const safeTotal = Number.isFinite(totalItems) && totalItems > 0 ? totalItems : 0;
  const safePageSize = Number.isFinite(pageSize) && pageSize > 0 ? pageSize : 1;
  const totalPages = Math.max(1, Math.ceil(safeTotal / safePageSize));

  if (safeTotal <= safePageSize) return null;

  const safePage = clamp(page, 1, totalPages);
  const startIndex = (safePage - 1) * safePageSize;
  const start = startIndex + 1;
  const end = Math.min(safeTotal, startIndex + safePageSize);

  const canPrev = safePage > 1;
  const canNext = safePage < totalPages;

  return (
    <nav className={styles.wrap} aria-label={ariaLabel ?? 'Pagination'}>
      <div className={styles.meta}>
        Showing <span className={styles.mono}>{start}</span>–<span className={styles.mono}>{end}</span> of{' '}
        <span className={styles.mono}>{safeTotal}</span>
      </div>
      <div className={styles.controls}>
        <button
          type="button"
          className={styles.btn}
          onClick={() => onPageChange(safePage - 1)}
          disabled={!canPrev}
          aria-label="Previous page"
        >
          Prev
        </button>
        <div className={styles.page}>
          Page <span className={styles.mono}>{safePage}</span> / <span className={styles.mono}>{totalPages}</span>
        </div>
        <button
          type="button"
          className={styles.btn}
          onClick={() => onPageChange(safePage + 1)}
          disabled={!canNext}
          aria-label="Next page"
        >
          Next
        </button>
      </div>
    </nav>
  );
}
