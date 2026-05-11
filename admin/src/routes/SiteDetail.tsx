import { useEffect, useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { api, type Site, type ProxyConfig } from '@/api/client';

export default function SiteDetail() {
  const { host = '' } = useParams();
  const navigate = useNavigate();
  const [site, setSite] = useState<Site | null>(null);
  const [config, setConfig] = useState<ProxyConfig | null>(null);
  const [certificate, setCertificate] = useState('');
  const [dnsProvider, setDnsProvider] = useState('');
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    (async () => {
      try {
        const [s, c] = await Promise.all([api.site(host), api.config()]);
        setSite(s);
        setConfig(c);
        setCertificate(s.certificate ?? '');
        setDnsProvider(s.dns_provider ?? '');
      } catch (e: unknown) {
        setError(String(e));
      }
    })();
  }, [host]);

  const save = async () => {
    if (!site) return;
    setSaving(true);
    setError(null);
    try {
      const updated = {
        ...site,
        certificate: certificate || null,
        dns_provider: dnsProvider || null,
      };
      const next = await api.updateSite(site.host, updated);
      setSite(next);
    } catch (e: unknown) {
      setError(String(e));
    } finally {
      setSaving(false);
    }
  };

  const deleteSite = async () => {
    if (!site) return;
    if (!confirm(`Delete site "${site.host}"?`)) return;
    await api.deleteSite(site.host);
    navigate('/sites');
  };

  if (error) {
    return <div className="error-banner"><i className="fas fa-exclamation-circle" />{error}</div>;
  }

  if (!site) {
    return <div className="spinner" />;
  }

  return (
    <div>
      <div className="page-header">
        <div className="page-title">
          <i className="fas fa-globe" />
          <h1>{site.host}</h1>
        </div>
        <div style={{ display: 'flex', gap: 8 }}>
          <Link className="btn btn-ghost" to="/sites">Back</Link>
          <button className="btn btn-danger" onClick={deleteSite}>Delete</button>
        </div>
      </div>

      <div className="card" style={{ maxWidth: 760, marginBottom: 16 }}>
        <h2 style={{ marginBottom: 12 }}>Reverse Proxy Site</h2>
        <div className="form-row">
          <div className="form-group">
            <label>Backend</label>
            <div className="badge badge-purple">{site.backend}</div>
          </div>
          <div className="form-group">
            <label>Certificate</label>
            <select value={certificate} onChange={e => setCertificate(e.target.value)}>
              <option value="">— none —</option>
              {[...new Set([...(site.certificate ? [site.certificate] : []), ...(config?.certificates ?? [])])].map(item => (
                <option key={item} value={item}>{item}</option>
              ))}
            </select>
          </div>
          <div className="form-group">
            <label>DNS Provider</label>
            <select value={dnsProvider} onChange={e => setDnsProvider(e.target.value)}>
              <option value="">— none —</option>
              {[...new Set([...(site.dns_provider ? [site.dns_provider] : []), ...(config?.dns_providers ?? [])])].map(item => (
                <option key={item} value={item}>{item}</option>
              ))}
            </select>
          </div>
        </div>

        <div className="form-group">
          <label>Routes</label>
          <table>
            <thead>
              <tr><th>Path</th><th>Type</th><th>Rewrite</th></tr>
            </thead>
            <tbody>
              {site.routes.map((route, idx) => (
                <tr key={idx}>
                  <td className="mono">{route.path}</td>
                  <td>{route.path_type}</td>
                  <td className="mono">{route.rewrite ?? '—'}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>

        <div style={{ display: 'flex', gap: 8, marginTop: 12 }}>
          <button className="btn btn-primary" onClick={save} disabled={saving}>
            {saving ? 'Applying…' : 'Provision Site'}
          </button>
          <span style={{ color: 'var(--color-muted)', alignSelf: 'center' }}>
            Provisioning here means storing the chosen certificate and DNS provider on the site record.
          </span>
        </div>
      </div>
    </div>
  );
}