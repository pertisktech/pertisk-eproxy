import FaIcon from "@/components/FaIcon";
import { useToast } from '@/context/ToastContext';
import styles from './Toaster.module.css';

export default function Toaster() {
  const { toasts, removeToast } = useToast();

  if (toasts.length === 0) return null;

  return (
    <div className={styles.container} role="region" aria-label="Notifications">
      {toasts.map((toast) => (
        <div
          key={toast.id}
          className={`${styles.toast} ${styles[toast.type]}`}
          role="alert"
          aria-live={toast.type === 'error' ? 'assertive' : 'polite'}
        >
          <span className={styles.icon} aria-hidden>
            {toast.type === 'success' && <FaIcon className="fas fa-check-circle" />}
            {toast.type === 'error' && <FaIcon className="fas fa-exclamation-circle" />}
            {toast.type === 'info' && <FaIcon className="fas fa-info-circle" />}
          </span>
          <span className={styles.message}>{toast.message}</span>
          <button
            type="button"
            className={styles.close}
            onClick={() => removeToast(toast.id)}
            aria-label="Dismiss"
          >
            <FaIcon className="fas fa-times" aria-hidden />
          </button>
        </div>
      ))}
    </div>
  );
}
