import { useState } from 'react';
import { api } from '@/api/client';
import styles from './Settings.module.css';

export default function Settings() {
  const [reloading, setReloading] = useState(false);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);

  const reload = async () => {
    setReloading(true);
    setMsg(null);
    try {
      await api.reload();
      setMsg({ ok: true, text: 'Config reloaded successfully.' });
    } catch (e: unknown) {
      setMsg({ ok: false, text: String(e) });
    } finally {
      setReloading(false);
    }
  };

  return (
    <div className={styles.page}>
      {msg && (
        <div className={msg.ok ? 'success-banner' : 'error-banner'}>
          <i className={`fas ${msg.ok ? 'fa-check-circle' : 'fa-exclamation-circle'}`} />
          {msg.text}
        </div>
      )}

      <div className="card">
        <h2 style={{ marginBottom: 12 }}>Hot Reload</h2>
        <button className="btn btn-primary" type="button" onClick={() => void reload()} disabled={reloading}>
          {reloading ? (
            <>
              <span className="spinner" style={{ width: 14, height: 14 }} /> Reloading…
            </>
          ) : (
            <>
              <i className="fas fa-sync-alt" /> Reload Config
            </>
          )}
        </button>
      </div>
    </div>
  );
}
