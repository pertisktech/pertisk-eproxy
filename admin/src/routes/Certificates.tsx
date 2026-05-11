import { useEffect, useState } from 'react';
import { api, type ProxyConfig } from '@/api/client';

export default function Certificates() {
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

  const saveModal = async () => {
    if (!config || !draftValue.trim()) return;
    const trimmed = draftValue.trim();

    if (editingIndex === null) {
      if (config.certificates.includes(trimmed)) {
        setError('Certificate already exists');
        return;
      }
      const next = { ...config, certificates: [...config.certificates, trimmed] };
      await save(next);
      setShowModal(false);
      return;
    }

    const nextCertificates = config.certificates.map((c, i) => (i === editingIndex ? trimmed : c));
    if (nextCertificates.some((c, i) => c === trimmed && i !== editingIndex)) {
      setError('Certificate already exists');
      return;
    }
    await save({ ...config, certificates: nextCertificates });
    setShowModal(false);
  };

  const remove = async (idx: number) => {
    if (!config) return;
    const next = { ...config, certificates: config.certificates.filter((_, i) => i !== idx) };
    await save(next);
  };

  return (
    <div>
      <div className="page-header">
        <div className="page-title">
          <i className="fas fa-certificate" />
          <h1>Certificates</h1>
        </div>
        <button className="btn btn-primary" onClick={openAdd}>
          <i className="fas fa-plus" /> Add Certificate
        </button>
      </div>

      {error && <div className="error-banner"><i className="fas fa-exclamation-circle" />{error}</div>}

      <div className="card">
        <p style={{ color: 'var(--color-text-secondary)', marginBottom: 12 }}>
          Manage SSL certificate names used by sites. These options appear in Add Site and Site Detail.
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
                {(config?.certificates ?? []).map((cert, idx) => (
                  <tr key={`${cert}-${idx}`}>
                    <td className="mono" style={{ color: 'var(--color-text)' }}>{cert}</td>
                    <td>
                      <button className="btn btn-ghost btn-sm" onClick={() => openEdit(idx, cert)} disabled={saving}>
                        <i className="fas fa-pen" />
                      </button>
                      <button className="btn btn-danger btn-sm" style={{ marginLeft: 8 }} onClick={() => remove(idx)} disabled={saving}>
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
                {editingIndex === null ? 'Add Certificate' : 'Edit Certificate'}
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
                placeholder="example-wildcard-cert"
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
