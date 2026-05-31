import FaIcon from "@/components/FaIcon";
import { useEffect } from 'react';
import styles from './ConfirmDialog.module.css';

export interface ConfirmDialogProps {
  open: boolean;
  title: string;
  message: string;
  primaryLabel?: string;
  cancelLabel?: string;
  variant?: 'danger' | 'default';
  loading?: boolean;
  onConfirm: () => void;
  onCancel: () => void;
}

export default function ConfirmDialog({
  open,
  title,
  message,
  primaryLabel = 'Confirm',
  cancelLabel = 'Cancel',
  variant = 'default',
  loading = false,
  onConfirm,
  onCancel,
}: ConfirmDialogProps) {
  useEffect(() => {
    if (!open) return;
    const handleEscape = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onCancel();
    };
    document.addEventListener('keydown', handleEscape);
    document.body.style.overflow = 'hidden';
    return () => {
      document.removeEventListener('keydown', handleEscape);
      document.body.style.overflow = '';
    };
  }, [open, onCancel]);

  if (!open) return null;

  return (
    <div
      className={styles.overlay}
      role="dialog"
      aria-modal="true"
      aria-labelledby="confirm-dialog-title"
      aria-describedby="confirm-dialog-desc"
      onClick={onCancel}
    >
      <div
        className={styles.panel}
        onClick={(e) => e.stopPropagation()}
      >
        <div className={styles.header}>
          <span
            className={variant === 'danger' ? styles.iconDanger : styles.iconDefault}
            aria-hidden
          >
            <FaIcon className={variant === 'danger' ? 'fas fa-triangle-exclamation' : 'fas fa-circle-info'} />
          </span>
          <div className={styles.headerText}>
            <h2 id="confirm-dialog-title" className={styles.title}>
              {title}
            </h2>
            <p id="confirm-dialog-desc" className={styles.message}>
              {message}
            </p>
          </div>
        </div>
        <div className={styles.actions}>
          <button
            type="button"
            className={styles.cancelBtn}
            onClick={onCancel}
            disabled={loading}
          >
            {cancelLabel}
          </button>
          <button
            type="button"
            className={variant === 'danger' ? styles.dangerBtn : styles.primaryBtn}
            onClick={onConfirm}
            disabled={loading}
          >
            {loading ? (
              <>
                <FaIcon className="fas fa-spinner fa-spin" aria-hidden /> …
              </>
            ) : (
              <>
                {variant === 'danger' ? <FaIcon className="fas fa-trash" aria-hidden /> : null}
                {primaryLabel}
              </>
            )}
          </button>
        </div>
      </div>
    </div>
  );
}
