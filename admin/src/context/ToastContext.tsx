import { createContext, useCallback, useContext, useMemo, useState } from 'react';

export type ToastType = 'success' | 'error' | 'info';

export interface Toast {
  id: string;
  type: ToastType;
  message: string;
  duration?: number;
}

type ToastContextValue = {
  toasts: Toast[];
  addToast: (type: ToastType, message: string, duration?: number) => void;
  removeToast: (id: string) => void;
  success: (message: string, duration?: number) => void;
  error: (message: string, duration?: number) => void;
  info: (message: string, duration?: number) => void;
};

const ToastContext = createContext<ToastContextValue | null>(null);

let toastId = 0;
function nextId() {
  return `toast-${Date.now()}-${++toastId}`;
}

const DEFAULT_DURATION = 5000;

export function ToastProvider({ children }: { children: React.ReactNode }) {
  const [toasts, setToasts] = useState<Toast[]>([]);

  const removeToast = useCallback((id: string) => {
    setToasts((prev) => prev.filter((t) => t.id !== id));
  }, []);

  const addToast = useCallback(
    (type: ToastType, message: string, duration = DEFAULT_DURATION) => {
      const id = nextId();
      const toast: Toast = { id, type, message, duration };
      setToasts((prev) => [...prev, toast]);
      if (duration > 0) {
        setTimeout(() => removeToast(id), duration);
      }
    },
    [removeToast]
  );

  const success = useCallback((message: string, duration?: number) => addToast('success', message, duration), [addToast]);
  const error = useCallback((message: string, duration?: number) => addToast('error', message, duration ?? 7000), [addToast]);
  const info = useCallback((message: string, duration?: number) => addToast('info', message, duration), [addToast]);

  const value = useMemo<ToastContextValue>(
    () => ({
      toasts,
      addToast,
      removeToast,
      success,
      error,
      info,
    }),
    [toasts, addToast, removeToast, success, error, info]
  );

  return <ToastContext.Provider value={value}>{children}</ToastContext.Provider>;
}

export function useToast() {
  const ctx = useContext(ToastContext);
  if (!ctx) throw new Error('useToast must be used within ToastProvider');
  return ctx;
}
