import { useEffect, useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import {
  api,
  type Site,
  type CertificateRow,
  type PathRewrite,
  type DnsProviderRow,
} from '@/api/client';

const PATH_TYPES = ['Prefix', 'Exact', 'ImplementationSpecific'] as const;

function toFormPathType(pt: string | undefined): string {
  if (!pt) return 'Prefix';
  const s = String(pt).toLowerCase();
  if (s === 'exact') return 'Exact';
  if (s === 'prefix') return 'Prefix';
  return 'ImplementationSpecific';
}

function toApiPathType(pt: string): PathRewrite['path_type'] {
  const u = (pt || 'Prefix').toLowerCase();
  if (u === 'exact') return 'exact';
  return 'prefix';
}

type RouteFormRow = { path: string; path_type: string; rewrite: string };

export default function SiteDetail() {
  const { host = '' } = useParams();
  const navigate = useNavigate();
  const [site, setSite] = useState<Site | null>(null);
  const [tlsRows, setTlsRows] = useState<CertificateRow[]>([]);
  const [dnsProviderRows, setDnsProviderRows] = useState<DnsProviderRow[]>([]);
  const [certificate, setCertificate] = useState('');
  const [dnsProvider, setDnsProvider] = useState('');
  const [routesForm, setRoutesForm] = useState<RouteFormRow[]>([{ path: '/', path_type: 'Prefix', rewrite: '/' }]);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    (async () => {
      try {
        const [s, tls, dns] = await Promise.all([
          api.site(host),
          api.certificates.list(),
          api.dnsProviders.list().catch(() => [] as DnsProviderRow[]),
        ]);
        setSite(s);
        setTlsRows(Array.isArray(tls) ? tls : []);
        setDnsProviderRows(Array.isArray(dns) ? dns : []);
        setCertificate(s.certificate ?? '');
        setDnsProvider(s.dns_provider ?? '');
        setRoutesForm(
          s.routes?.length
            ? s.routes.map((r) => ({
                path: r.path ?? '/',
                path_type: toFormPathType(r.path_type),
                rewrite: r.rewrite ?? '',
              }))
            : [{ path: '/', path_type: 'Prefix', rewrite: '/' }],
        );
      } catch (e: unknown) {
        setError(String(e));
      }
    })();
  }, [host]);

  function addRoute() {
    setRoutesForm((r) => [...r, { path: '', path_type: 'Prefix', rewrite: '' }]);
  }

  function removeRoute(i: number) {
    setRoutesForm((r) => r.filter((_, idx) => idx !== i));
  }

  function updateRoute(i: number, field: keyof RouteFormRow, value: string) {
    setRoutesForm((rows) => {
      const next = [...rows];
      next[i] = { ...next[i], [field]: value };
      return next;
    });
  }

  const save = async () => {
    if (!site) return;
    setSaving(true);
    setError(null);
    try {
      const routes: PathRewrite[] = routesForm
        .map((r) => ({
          path: r.path.trim(),
          path_type: toApiPathType(r.path_type),
          rewrite: r.rewrite.trim() || undefined,
        }))
        .filter((r) => r.path);
      if (routes.length === 0) {
        setError('At least one route with a non-empty path is required.');
        return;
      }
      const updated = {
        ...site,
        certificate: certificate || null,
        dns_provider: dnsProvider || null,
        routes,
      };
      const next = await api.updateSite(site.host, updated);
      setSite(next);
      setRoutesForm(
        next.routes?.length
          ? next.routes.map((r) => ({
              path: r.path ?? '/',
              path_type: toFormPathType(r.path_type),
              rewrite: r.rewrite ?? '',
            }))
          : [{ path: '/', path_type: 'Prefix', rewrite: '/' }],
      );
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
      <div className="page-actions">
        <Link className="btn btn-ghost" to="/sites">Back</Link>
        <button className="btn btn-danger" onClick={deleteSite}>Delete</button>
      </div>

      <div className="card" style={{ maxWidth: 760, marginBottom: 16 }}>
        <div className="form-row">
          <div className="form-group">
            <label>Backend</label>
            <div className="badge badge-purple">{site.backend}</div>
          </div>
          <div className="form-group">
            <label>Certificate</label>
            <select value={certificate} onChange={(e) => setCertificate(e.target.value)}>
              <option value="">— none —</option>
              {tlsRows.map((r) => (
                <option key={r.id} value={r.id}>
                  {(r.hosts?.length ? r.hosts.join(' · ') : r.id) + (r.source_type ? ` (${r.source_type})` : '')}
                </option>
              ))}
              {certificate &&
              !tlsRows.some((r) => r.id === certificate) ? (
                <option value={certificate}>{certificate} (saved)</option>
              ) : null}
            </select>
          </div>
          <div className="form-group">
            <label>DNS Provider</label>
            <select value={dnsProvider} onChange={(e) => setDnsProvider(e.target.value)}>
              <option value="">— none —</option>
              {dnsProviderRows.map((row) => (
                <option key={row.id || row.name} value={row.name}>
                  {row.provider_type ? `${row.name} (${row.provider_type})` : row.name}
                </option>
              ))}
              {dnsProvider &&
              !dnsProviderRows.some((r) => r.name === dnsProvider) ? (
                <option value={dnsProvider}>{dnsProvider} (saved)</option>
              ) : null}
            </select>
            {dnsProviderRows.length === 0 ? (
              <p className="hint" style={{ marginTop: 6, fontSize: '0.85rem', color: 'var(--text-muted)' }}>
                No DNS providers configured. <Link to="/dns-providers">Add one</Link>.
              </p>
            ) : null}
          </div>
        </div>

        <div className="form-group">
          <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 8, marginBottom: 8 }}>
            <label style={{ margin: 0 }}>Routes</label>
            <button type="button" className="btn btn-ghost btn-sm" onClick={addRoute}>
              Add route
            </button>
          </div>
          <table style={{ width: '100%' }}>
            <thead>
              <tr>
                <th>Type</th>
                <th>Path</th>
                <th>Rewrite</th>
                <th style={{ width: '1%' }} aria-label="Remove" />
              </tr>
            </thead>
            <tbody>
              {routesForm.map((route, idx) => (
                <tr key={idx}>
                  <td>
                    <select
                      value={route.path_type}
                      onChange={(e) => updateRoute(idx, 'path_type', e.target.value)}
                      style={{ width: '100%', minWidth: '8rem' }}
                    >
                      {PATH_TYPES.map((t) => (
                        <option key={t} value={t}>
                          {t}
                        </option>
                      ))}
                    </select>
                  </td>
                  <td>
                    <input
                      type="text"
                      className="mono"
                      value={route.path}
                      onChange={(e) => updateRoute(idx, 'path', e.target.value)}
                      placeholder="/api"
                      style={{ width: '100%' }}
                    />
                  </td>
                  <td>
                    <input
                      type="text"
                      className="mono"
                      value={route.rewrite}
                      onChange={(e) => updateRoute(idx, 'rewrite', e.target.value)}
                      placeholder="optional"
                      style={{ width: '100%' }}
                    />
                  </td>
                  <td>
                    <button
                      type="button"
                      className="btn btn-ghost btn-sm"
                      onClick={() => removeRoute(idx)}
                      disabled={routesForm.length <= 1}
                      title="Remove route"
                    >
                      ×
                    </button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>

        <div style={{ display: 'flex', gap: 8, marginTop: 12 }}>
          <button type="button" className="btn btn-primary" onClick={() => void save()} disabled={saving}>
            {saving ? 'Saving…' : 'Save changes'}
          </button>
        </div>
      </div>
    </div>
  );
}