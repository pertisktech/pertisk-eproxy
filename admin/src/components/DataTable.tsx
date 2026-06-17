import FaIcon from '@/components/FaIcon';
import type { ReactNode } from 'react';
import styles from './DataTable.module.css';

export type SortDirection = 'asc' | 'desc';

export type SortState = {
  key: string;
  direction: SortDirection;
};

export type DataTableColumn<T> = {
  header: string;
  sortKey?: string;
  sortable?: boolean;
  width?: string;
  headerClassName?: string;
  cellClassName?: string;
  render: (row: T, rowIndex: number) => ReactNode;
};

type DataTableProps<T> = {
  columns: DataTableColumn<T>[];
  data: T[];
  rowKey: (row: T) => string;
  isLoading?: boolean;
  error?: string | null;
  emptyMessage?: string;
  sortState?: SortState | null;
  onSortChange?: (sort: SortState) => void;
  onRowClick?: (row: T) => void;
  selectedRowKey?: string;
  totalLabel?: string;
};

function SortHeader({
  header,
  sortKey,
  sortState,
  onSortChange,
}: {
  header: string;
  sortKey: string;
  sortState?: SortState | null;
  onSortChange: (sort: SortState) => void;
}) {
  const active = sortState?.key === sortKey;
  const direction = active ? sortState.direction : null;
  const nextDirection: SortDirection = active && direction === 'asc' ? 'desc' : 'asc';
  const iconClass = !active
    ? 'fas fa-sort'
    : direction === 'asc'
      ? 'fas fa-sort-up'
      : 'fas fa-sort-down';

  return (
    <button
      type="button"
      className={styles.sortBtn}
      onClick={() => onSortChange({ key: sortKey, direction: nextDirection })}
      aria-label={`Sort by ${header}`}
    >
      <span>{header}</span>
      <FaIcon className={`${styles.sortIcon} ${active ? styles.sortIconActive : ''} ${iconClass}`} aria-hidden />
    </button>
  );
}

export default function DataTable<T>({
  columns,
  data,
  rowKey,
  isLoading = false,
  error = null,
  emptyMessage = 'No data available',
  sortState = null,
  onSortChange,
  onRowClick,
  selectedRowKey,
  totalLabel,
}: DataTableProps<T>) {
  if (error) {
    return <p className={styles.error}>Error loading data: {error}</p>;
  }

  const totalText = totalLabel ?? `Total: ${data.length} record${data.length === 1 ? '' : 's'}`;

  return (
    <div className={styles.wrap}>
      <div className={styles.toolbar}>{totalText}</div>
      <div className={styles.scroll}>
        <table className={styles.table}>
          <thead>
            <tr>
              {columns.map((col) => (
                <th
                  key={col.header}
                  className={col.headerClassName}
                  style={col.width ? { width: col.width } : undefined}
                  aria-sort={
                    col.sortable && col.sortKey && sortState?.key === col.sortKey
                      ? sortState.direction === 'asc'
                        ? 'ascending'
                        : 'descending'
                      : 'none'
                  }
                >
                  {col.sortable && col.sortKey && onSortChange ? (
                    <SortHeader
                      header={col.header}
                      sortKey={col.sortKey}
                      sortState={sortState}
                      onSortChange={onSortChange}
                    />
                  ) : (
                    col.header
                  )}
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            {isLoading ? (
              <tr>
                <td colSpan={columns.length} className={styles.stateLoading}>
                  <span className="spinner" aria-hidden />
                  <span>Loading…</span>
                </td>
              </tr>
            ) : data.length === 0 ? (
              <tr>
                <td colSpan={columns.length} className={styles.stateCell}>
                  {emptyMessage}
                </td>
              </tr>
            ) : (
              data.map((row, rowIndex) => {
                const key = rowKey(row);
                const selected = selectedRowKey === key;
                return (
                  <tr
                    key={key}
                    className={[
                      rowIndex % 2 === 0 ? styles.rowEven : styles.rowOdd,
                      onRowClick ? styles.rowClickable : '',
                      selected ? styles.rowSelected : '',
                    ]
                      .filter(Boolean)
                      .join(' ')}
                    onClick={onRowClick ? () => onRowClick(row) : undefined}
                  >
                    {columns.map((col) => (
                      <td key={col.header} className={col.cellClassName}>
                        {col.render(row, rowIndex)}
                      </td>
                    ))}
                  </tr>
                );
              })
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}
