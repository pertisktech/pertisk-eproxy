import { useEffect, useState, useCallback } from 'react';
import { Link } from 'react-router-dom';
import { api, type Site, type PathRewrite, type PathType } from '@/api/client';
import styles from './Sites.module.css';

const EMPTY_ROUTE: PathRewrite = { path: '/', path_type: 'prefix' };

function uniq(items: string[]) {
  return Array.from(new Set(items.map(s => s.trim()).filter(Boolean)));
}

function SiteModal({
  site,
  onClose,
  onSaved,
  certificates,
  dnsProviders,
}: {
  site?: Site;
  onClose: () => void;
  onSaved: () => void;
  certificates: string[];
  dnsProviders: string[];
}) {
  const [host, setHost]       = useState(site?.host ?? '');
  const [backend, setBackend] = useState(site?.backend ?? '');
  const [certificate, setCertificate] = useState(site?.certificate ?? '');
  const [dnsProvider, setDnsProvider] = useState(site?.dns_provider ?? '');
  const [certOptions, setCertOptions] = useState<string[]>(uniq([...(site?.certificate ? [site.certificate] : []), ...certificates]));
  const [dnsOptions, setDnsOptions] = useState<string[]>(uniq([...(site?.dns_provider ? [site.dns_provider] : []), ...dnsProviders]));
  const [editingCertIndex, setEditingCertIndex] = useState<number | null>(null);
  const [editingCertValue, setEditingCertValue] = useState('');
  const [editingDnsIndex, setEditingDnsIndex] = useState<number | null>(null);
  const [editingDnsValue, setEditingDnsValue] = useState('');
  const [routes, setRoutes]   = useState<PathRewrite[]>(site?.routes?.length ? site.routes : [{ ...EMPTY_ROUTE }]);
  const [showAdvancedRoutes, setShowAdvancedRoutes] = useState(!!site);
  const [saving, setSaving]   = useState(false);
  const [updatingRecords, setUpdatingRecords] = useState(false);
  const [error, setError]     = useState<string | null>(null);

  const isEditing = !!site;

  useEffect(() => {
    setHost(site?.host ?? '');
    setBackend(site?.backend ?? '');
    setCertificate(site?.certificate ?? '');
    setDnsProvider(site?.dns_provider ?? '');
    setCertOptions(uniq([...(site?.certificate ? [site.certificate] : []), ...certificates]));
    setDnsOptions(uniq([...(site?.dns_provider ? [site.dns_provider] : []), ...dnsProviders]));
    setRoutes(site?.routes?.length ? site.routes : [{ ...EMPTY_ROUTE }]);
    setShowAdvancedRoutes(!!site);
    setError(null);
    setSaving(false);
    setUpdatingRecords(false);
    setEditingCertIndex(null);
    setEditingCertValue('');
    setEditingDnsIndex(null);
    setEditingDnsValue('');
  }, [site, certificates, dnsProviders]);

  const updateRoute = (i: number, key: keyof PathRewrite, value: string) =>
    setRoutes(rs => rs.map((r, idx) => idx === i ? { ...r, [key]: value || undefined } : r));

  const addCertificateToList = async () => {
    const nextValue = certificate.trim();
    if (!nextValue || certOptions.includes(nextValue)) return;
    setUpdatingRecords(true);
    setError(null);
    try {
      const c = await api.config();
      await api.putConfig({ ...c, certificates: uniq([...c.certificates, nextValue]) });
      setCertOptions(opts => uniq([...opts, nextValue]));
    } catch (e: unknown) {
      setError(String(e));
    } finally {
      setUpdatingRecords(false);
    }
  };

  const addDnsToList = async () => {
    const nextValue = dnsProvider.trim();
    if (!nextValue || dnsOptions.includes(nextValue)) return;
    setUpdatingRecords(true);
    setError(null);
    try {
      const c = await api.config();
      await api.putConfig({ ...c, dns_providers: uniq([...c.dns_providers, nextValue]) });
      setDnsOptions(opts => uniq([...opts, nextValue]));
    } catch (e: unknown) {
      setError(String(e));
    } finally {
      setUpdatingRecords(false);
    }
  };

  const removeCertificateFromList = async (idx: number) => {
    const value = certOptions[idx];
    if (!value) return;
    setUpdatingRecords(true);
    setError(null);
    try {
      const c = await api.config();
      await api.putConfig({ ...c, certificates: c.certificates.filter(v => v !== value) });
      setCertOptions(opts => opts.filter((_, i) => i !== idx));
      if (certificate === value) setCertificate('');
    } catch (e: unknown) {
      setError(String(e));
    } finally {
      setUpdatingRecords(false);
    }
  };

  const removeDnsFromList = async (idx: number) => {
    const value = dnsOptions[idx];
    if (!value) return;
    setUpdatingRecords(true);
    setError(null);
    try {
      const c = await api.config();
      await api.putConfig({ ...c, dns_providers: c.dns_providers.filter(v => v !== value) });
      setDnsOptions(opts => opts.filter((_, i) => i !== idx));
      if (dnsProvider === value) setDnsProvider('');
    } catch (e: unknown) {
      setError(String(e));
    } finally {
      setUpdatingRecords(false);
    }
  };

  const saveEditedCertificate = async () => {
    if (editingCertIndex === null) return;
    const oldValue = certOptions[editingCertIndex];
    const newValue = editingCertValue.trim();
    if (!oldValue || !newValue) return;
    if (certOptions.some((c, i) => c === newValue && i !== editingCertIndex)) {
      setError('Certificate already exists');
      return;
    }
    setUpdatingRecords(true);
    setError(null);
    try {
      const c = await api.config();
      const next = c.certificates.map(v => (v === oldValue ? newValue : v));
      await api.putConfig({ ...c, certificates: uniq(next) });
      setCertOptions(opts => opts.map((v, i) => (i === editingCertIndex ? newValue : v)));
      if (certificate === oldValue) setCertificate(newValue);
      setEditingCertIndex(null);
      setEditingCertValue('');
    } catch (e: unknown) {
      setError(String(e));
    } finally {
      setUpdatingRecords(false);
    }
  };

  const saveEditedDns = async () => {
    if (editingDnsIndex === null) return;
    const oldValue = dnsOptions[editingDnsIndex];
    const newValue = editingDnsValue.trim();
    if (!oldValue || !newValue) return;
    if (dnsOptions.some((d, i) => d === newValue && i !== editingDnsIndex)) {
      setError('DNS provider already exists');
      return;
    }
    setUpdatingRecords(true);
    setError(null);
    try {
      const c = await api.config();
      const next = c.dns_providers.map(v => (v === oldValue ? newValue : v));
      await api.putConfig({ ...c, dns_providers: uniq(next) });
      setDnsOptions(opts => opts.map((v, i) => (i === editingDnsIndex ? newValue : v)));
      if (dnsProvider === oldValue) setDnsProvider(newValue);
      setEditingDnsIndex(null);
      setEditingDnsValue('');
    } catch (e: unknown) {
      setError(String(e));
    } finally {
      setUpdatingRecords(false);
    }
  };

  const save = async () => {
    if (!host.trim()) { setError('Host is required'); return; }
    if (!backend.trim()) { setError('Backend is required'); return; }
    setSaving(true);
    try {
      const draft: Site = {
        host: host.trim(),
        backend: backend.trim(),
        certificate: certificate.trim() || null,
        dns_provider: dnsProvider.trim() || null,
        routes: routes.length === 0 ? [{ ...EMPTY_ROUTE }] : routes,
      };
      if (isEditing && site?.host) {
        await api.updateSite(site.host, draft);
      } else {
        await api.addSite(draft);
      }
      onSaved();
      onClose();
    } catch (e: unknown) { setError(String(e)); }
    finally { setSaving(false); }
  };

  return (
    <div className="modal-overlay" onClick={e => e.target === e.currentTarget && onClose()}>
      <div className="modal">
        <div className="modal-header">
          <div className="modal-title"><i className="fas fa-globe" /> {isEditing ? 'Edit Site' : 'Add Site'}</div>
          <button className="modal-close btn" onClick={onClose}><i className="fas fa-times" /></button>
        </div>

        {error && <div className="error-banner"><i className="fas fa-exclamation-circle" />{error}</div>}

        <div className="form-group">
          <label>Domain</label>
          <input value={host} onChange={e => setHost(e.target.value)} placeholder="example.com" />
        </div>

        <div className="form-group">
          <label>Backend</label>
          <input value={backend} onChange={e => setBackend(e.target.value)} placeholder="backend name or target" />
        </div>

        <div className="form-group">
          <label>SSL Certificate</label>
          <div className={styles.optionInputRow}>
            <input
              value={certificate}
              onChange={e => setCertificate(e.target.value)}
              list="site-cert-options"
              placeholder="example-wildcard-cert"
            />
            <button
              type="button"
              className="btn btn-ghost btn-sm"
              onClick={addCertificateToList}
              disabled={updatingRecords || !certificate.trim() || certOptions.includes(certificate.trim())}
            >
              Add
            </button>
          </div>
          <datalist id="site-cert-options">
            {certOptions.map(cert => <option key={cert} value={cert} />)}
          </datalist>
          <div className={styles.modalRecordTable}>
            <table>
              <thead>
                <tr>
                  <th>Name</th>
                  <th style={{ width: 130 }}></th>
                </tr>
              </thead>
              <tbody>
                {certOptions.map((cert, idx) => (
                  <tr key={`${cert}-${idx}`}>
                    <td>
                      {editingCertIndex === idx ? (
                        <input
                          className={styles.recordEditInput}
                          value={editingCertValue}
                          onChange={e => setEditingCertValue(e.target.value)}
                        />
                      ) : (
                        <button type="button" className={`badge badge-purple ${styles.optionChipBtn}`} onClick={() => setCertificate(cert)}>{cert}</button>
                      )}
                    </td>
                    <td>
                      {editingCertIndex === idx ? (
                        <>
                          <button type="button" className="btn btn-primary btn-sm" onClick={saveEditedCertificate} disabled={updatingRecords}><i className="fas fa-check" /></button>
                          <button type="button" className="btn btn-ghost btn-sm" style={{ marginLeft: 8 }} onClick={() => { setEditingCertIndex(null); setEditingCertValue(''); }} disabled={updatingRecords}><i className="fas fa-times" /></button>
                        </>
                      ) : (
                        <>
                          <button type="button" className="btn btn-ghost btn-sm" onClick={() => { setEditingCertIndex(idx); setEditingCertValue(cert); }} disabled={updatingRecords}><i className="fas fa-pen" /></button>
                          <button type="button" className="btn btn-danger btn-sm" style={{ marginLeft: 8 }} onClick={() => removeCertificateFromList(idx)} disabled={updatingRecords}><i className="fas fa-trash" /></button>
                        </>
                      )}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>

        <div className="form-group">
          <label>DNS Provider</label>
          <div className={styles.optionInputRow}>
            <input
              value={dnsProvider}
              onChange={e => setDnsProvider(e.target.value)}
              list="site-dns-options"
              placeholder="cloudflare"
            />
            <button
              type="button"
              className="btn btn-ghost btn-sm"
              onClick={addDnsToList}
              disabled={updatingRecords || !dnsProvider.trim() || dnsOptions.includes(dnsProvider.trim())}
            >
              Add
            </button>
          </div>
          <datalist id="site-dns-options">
            {dnsOptions.map(dns => <option key={dns} value={dns} />)}
          </datalist>
          <div className={styles.modalRecordTable}>
            <table>
              <thead>
                <tr>
                  <th>Name</th>
                  <th style={{ width: 130 }}></th>
                </tr>
              </thead>
              <tbody>
                {dnsOptions.map((dns, idx) => (
                  <tr key={`${dns}-${idx}`}>
                    <td>
                      {editingDnsIndex === idx ? (
                        <input
                          className={styles.recordEditInput}
                          value={editingDnsValue}
                          onChange={e => setEditingDnsValue(e.target.value)}
                        />
                      ) : (
                        <button type="button" className={`badge badge-purple ${styles.optionChipBtn}`} onClick={() => setDnsProvider(dns)}>{dns}</button>
                      )}
                    </td>
                    <td>
                      {editingDnsIndex === idx ? (
                        <>
                          <button type="button" className="btn btn-primary btn-sm" onClick={saveEditedDns} disabled={updatingRecords}><i className="fas fa-check" /></button>
                          <button type="button" className="btn btn-ghost btn-sm" style={{ marginLeft: 8 }} onClick={() => { setEditingDnsIndex(null); setEditingDnsValue(''); }} disabled={updatingRecords}><i className="fas fa-times" /></button>
                        </>
                      ) : (
                        <>
                          <button type="button" className="btn btn-ghost btn-sm" onClick={() => { setEditingDnsIndex(idx); setEditingDnsValue(dns); }} disabled={updatingRecords}><i className="fas fa-pen" /></button>
                          <button type="button" className="btn btn-danger btn-sm" style={{ marginLeft: 8 }} onClick={() => removeDnsFromList(idx)} disabled={updatingRecords}><i className="fas fa-trash" /></button>
                        </>
                      )}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>

        <div className="card" style={{ marginBottom: 16, padding: 12 }}>
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', gap: 8 }}>
            <div>
              <strong>Reverse Proxy Rule</strong>
              <div style={{ color: 'var(--color-muted)', fontSize: 12 }}>
                Default: forward all paths from this domain to the selected backend.
              </div>
            </div>
            <button type="button" className="btn btn-ghost btn-sm" onClick={() => setShowAdvancedRoutes(v => !v)}>
              {showAdvancedRoutes ? 'Hide Advanced Routes' : 'Show Advanced Routes'}
            </button>
          </div>

          {!showAdvancedRoutes && (
            <div style={{ marginTop: 8 }} className="mono">
              <span style={{ color: 'var(--color-text-secondary)' }}>/[all paths]</span> → <span style={{ color: 'var(--color-text)' }}>{backend || 'select backend'}</span>
            </div>
          )}

          {showAdvancedRoutes && (
            <div className="form-group" style={{ marginTop: 10, marginBottom: 0 }}>
              <label>Routes</label>
              <div className={styles.routeList}>
                {routes.map((r, i) => (
                  <div key={i} className={styles.routeRow}>
                    <input
                      value={r.path}
                      onChange={e => updateRoute(i, 'path', e.target.value)}
                      placeholder="/path"
                    />
                    <select
                      value={r.path_type}
                      onChange={e => updateRoute(i, 'path_type', e.target.value as PathType)}
                      style={{ width: 'auto' }}
                    >
                      <option value="prefix">prefix</option>
                      <option value="exact">exact</option>
                    </select>
                    <input
                      value={r.rewrite ?? ''}
                      onChange={e => updateRoute(i, 'rewrite', e.target.value)}
                      placeholder="rewrite (optional)"
                    />
                    <button
                      type="button"
                      className={styles.routeRemove}
                      onClick={() => setRoutes(rs => rs.filter((_, idx) => idx !== i))}
                      title="Remove"
                    >
                      <i className="fas fa-minus-circle" />
                    </button>
                  </div>
                ))}
              </div>
              <button
                type="button"
                className={styles.addRouteBtn}
                onClick={() => setRoutes(rs => [...rs, { ...EMPTY_ROUTE }])}
              >
                <i className="fas fa-plus" /> Add route
              </button>
            </div>
          )}
        </div>

        <div className="modal-footer">
          <button className="btn btn-ghost" onClick={onClose}>Cancel</button>
          <button className="btn btn-primary" onClick={save} disabled={saving}>
            {saving ? <><span className="spinner" style={{ width: 14, height: 14 }} /> Saving…</> : (isEditing ? 'Update Site' : 'Save Site')}
          </button>
        </div>
      </div>
    </div>
  );
}

export default function Sites() {
  const [sites, setSites]       = useState<Site[]>([]);
  const [certificates, setCertificates] = useState<string[]>([]);
  const [dnsProviders, setDnsProviders] = useState<string[]>([]);
  const [loading, setLoading]   = useState(true);
  const [error, setError]       = useState<string | null>(null);
  const [showAdd, setShowAdd]   = useState(false);
  const [editingSite, setEditingSite] = useState<Site | null>(null);
  const [deleting, setDeleting] = useState<string | null>(null);

  const load = useCallback(async () => {
    try {
      const [c, s] = await Promise.all([api.config(), api.sites()]);
      setCertificates(c.certificates ?? []);
      setDnsProviders(c.dns_providers ?? []);
      setSites(s);
      setError(null);
    } catch (e: unknown) { setError(String(e)); }
    finally { setLoading(false); }
  }, []);

  useEffect(() => { load(); }, [load]);

  const deleteSite = async (host: string) => {
    if (!confirm(`Delete site "${host}"?`)) return;
    setDeleting(host);
    try { await api.deleteSite(host); await load(); }
    catch (e: unknown) { setError(String(e)); }
    finally { setDeleting(null); }
  };

  return (
    <div>
      <div className="page-header">
        <div className="page-title">
          <i className="fas fa-globe" />
          <h1>Sites</h1>
        </div>
        <button className="btn btn-primary" onClick={() => setShowAdd(true)}>
          <i className="fas fa-plus" /> Add Site
        </button>
      </div>

      {error && <div className="error-banner"><i className="fas fa-exclamation-circle" />{error}</div>}

      {loading ? (
        <div style={{ display: 'flex', justifyContent: 'center', padding: '60px' }}>
          <div className="spinner" />
        </div>
      ) : (
        <div className="card" style={{ padding: 0 }}>
          {sites.length === 0 ? (
            <div style={{ padding: '40px', textAlign: 'center', color: 'var(--color-muted)' }}>
              No sites yet. Click <strong>Add Site</strong> to get started.
            </div>
          ) : (
            <table>
              <thead>
                <tr>
                  <th>Host</th>
                  <th>Backend</th>
                  <th>Certificate</th>
                  <th>DNS Provider</th>
                  <th>Routes</th>
                  <th style={{ width: 60 }}></th>
                </tr>
              </thead>
              <tbody>
                {sites.map(s => (
                  <tr key={s.host}>
                    <td>
                      <Link to={`/sites/${encodeURIComponent(s.host)}`} style={{ color: 'inherit', textDecoration: 'none' }}>
                        <span className="mono" style={{ color: 'var(--color-text)', fontWeight: 600 }}>{s.host}</span>
                      </Link>
                    </td>
                    <td><span className="badge badge-purple">{s.backend}</span></td>
                    <td>
                      {s.certificate ? (
                        <div className={styles.fitWidthList}>
                          <span className="badge badge-purple">{s.certificate}</span>
                        </div>
                      ) : <span style={{ color: 'var(--color-muted)' }}>—</span>}
                    </td>
                    <td>
                      {s.dns_provider ? (
                        <div className={styles.fitWidthList}>
                          <span className="badge badge-purple">{s.dns_provider}</span>
                        </div>
                      ) : <span style={{ color: 'var(--color-muted)' }}>—</span>}
                    </td>
                    <td>
                      <div style={{ display: 'flex', flexDirection: 'column', gap: 3 }}>
                        {s.routes.map((r, i) => (
                          <div key={i} style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
                            <span className="mono" style={{ color: 'var(--color-text)' }}>{r.path}</span>
                            <span className="badge badge-purple" style={{ fontSize: 10 }}>{r.path_type}</span>
                            {r.rewrite && <span className="mono" style={{ color: 'var(--color-muted)' }}>→ {r.rewrite}</span>}
                          </div>
                        ))}
                      </div>
                    </td>
                    <td>
                      <button
                        className="btn btn-danger btn-sm"
                        onClick={() => deleteSite(s.host)}
                        disabled={deleting === s.host}
                      >
                        {deleting === s.host ? <span className="spinner" style={{ width: 12, height: 12 }} /> : <i className="fas fa-trash" />}
                      </button>
                      <button
                        className="btn btn-ghost btn-sm"
                        style={{ marginLeft: 8 }}
                        onClick={() => setEditingSite(s)}
                      >
                        <i className="fas fa-pen" />
                      </button>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </div>
      )}

      {showAdd && (
        <SiteModal
          onClose={() => setShowAdd(false)}
          onSaved={load}
          certificates={certificates}
          dnsProviders={dnsProviders}
        />
      )}

      {editingSite && (
        <SiteModal
          site={editingSite}
          onClose={() => setEditingSite(null)}
          onSaved={load}
          certificates={certificates}
          dnsProviders={dnsProviders}
        />
      )}
    </div>
  );
}
