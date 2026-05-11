import { useEffect, useState } from 'react';
import { api, type ProxyConfig } from '@/api/client';

export default function DnsProviders() {
  const [config, setConfig] = useState<ProxyConfig | null>(null);
  const [showModal, setShowModal] = useState(false);
  const [editingIndex, setEditingIndex] = useState<number | null>(null);
  const [draftValue, setDraftValue] = useState('');
  const [saving, setSaving] = useState(false);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    (async () => {
      try {
        setConfig(await api.config());
      } catch (e: unknown) {
        setError(String(e));
      } finally {
        setLoading(false);
      }
    })();
  }, []);

  const save = async (next: ProxyConfig) => {
    setSaving(true);
    setError(null);
    try {
      await api.putConfig(next);
      setConfig(next);
    } catch (e: unknown) {
      setError(String(e));
    } finally {
      setSaving(false);
    }
  };

  const openAdd = () => {
    setEditingIndex(null);
    setDraftValue('');
    setShowModal(true);
  };

  const openEdit = (idx: number, value: string) => {
    setEditingIndex(idx);
    setDraftValue(value);
    setShowModal(true);
  };

  const remove = async (idx: number) => {
    if (!config) return;
    const next = { ...config, dns_providers: config.dns_providers.filter((_, i) => i !== idx) };
    await save(next);
  };

  const saveModal = async () => {
    if (!config || !draftValue.trim()) return;
    const trimmed = draftValue.trim();

    if (editingIndex === null) {
      if (config.dns_providers.includes(trimmed)) {
        setError('DNS provider already exists');
        return;
      }
      await save({ ...config, dns_providers: [...config.dns_providers, trimmed] });
      setShowModal(false);
      return;
    }

    const nextProviders = config.dns_providers.map((p, i) => (i === editingIndex ? trimmed : p));
    if (nextProviders.some((p, i) => p === trimmed && i !== editingIndex)) {
      setError('DNS provider already exists');
      return;
    }
    await save({ ...config, dns_providers: nextProviders });
    setShowModal(false);
  };

  return (
    <div>
      <div className="page-header">
        <div className="page-title">
          <i className="fas fa-network-wired" />
          <h1>DNS Providers</h1>
        </div>
        <button className="btn btn-primary" onClick={openAdd}>
          <i className="fas fa-plus" /> Add DNS Provider
        </button>
      </div>

      {error && <div className="error-banner"><i className="fas fa-exclamation-circle" />{error}</div>}

      <div className="card">
        <p style={{ color: 'var(--color-text-secondary)', marginBottom: 12 }}>
          Manage DNS provider names used by sites. These options appear in Add Site and Site Detail.
        </p>

        {loading ? (
          <div className="spinner" />
        ) : (
          <>
            <table>
              <thead>
                <tr>
                  <th>Name</th>
                  <th style={{ width: 150 }}></th>
                </tr>
              </thead>
              <tbody>
                {(config?.dns_providers ?? []).map((provider, idx) => (
                  <tr key={`${provider}-${idx}`}>
                    <td className="mono" style={{ color: 'var(--color-text)' }}>{provider}</td>
                    <td>
                      <button className="btn btn-ghost btn-sm" onClick={() => openEdit(idx, provider)} disabled={saving}>
                        <i className="fas fa-pen" />
                      </button>
                      <button className="btn btn-danger btn-sm" onClick={() => remove(idx)} disabled={saving} style={{ marginLeft: 8 }}>
                        <i className="fas fa-trash" />
                      </button>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </>
        )}
      </div>

      {showModal && (
        <div className="modal-overlay" onClick={e => e.target === e.currentTarget && setShowModal(false)}>
          <div className="modal">
            <div className="modal-header">
              <div className="modal-title">
                <i className={`fas ${editingIndex === null ? 'fa-plus' : 'fa-pen'}`} />
                {editingIndex === null ? 'Add DNS Provider' : 'Edit DNS Provider'}
              </div>
              <button className="modal-close btn" onClick={() => setShowModal(false)}>
                <i className="fas fa-times" />
              </button>
            </div>

            <div className="form-group">
              <label>Name</label>
              <input
                value={draftValue}
                onChange={e => setDraftValue(e.target.value)}
                placeholder="cloudflare"
              />
            </div>

            <div className="modal-footer">
              <button className="btn btn-ghost" onClick={() => setShowModal(false)}>Cancel</button>
              <button className="btn btn-primary" onClick={saveModal} disabled={saving || !draftValue.trim()}>
                {saving ? 'Saving…' : (editingIndex === null ? 'Add' : 'Save')}
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
