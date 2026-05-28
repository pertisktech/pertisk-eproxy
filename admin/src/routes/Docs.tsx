import { useMemo } from 'react';
import { MANAGEMENT_API_ROUTES } from '@/managementApiRoutes';
import { buildManagementOpenApi } from '@/managementApiOpenapi';
import SwaggerUI from 'swagger-ui-react';
import 'swagger-ui-react/swagger-ui.css';
import styles from './Docs.module.css';

function methodBadgeClass(method: string): string {
  if (method === 'GET' || method === 'HEAD') return 'badge-green';
  if (method === 'DELETE') return 'badge-red';
  if (method === 'PUT') return 'badge-yellow';
  return 'badge-purple';
}

function getVersionLabel(): string {
  const v = import.meta.env?.VITE_APP_VERSION as string | undefined;
  if (!v) return '0.0.0';
  return v.startsWith('v') ? v.slice(1) : v;
}

export default function Docs() {
  const openapi = useMemo(() => buildManagementOpenApi(getVersionLabel()), []);
  const openapiJson = useMemo(() => JSON.stringify(openapi, null, 2), [openapi]);

  const downloadOpenApi = () => {
    const blob = new Blob([openapiJson], { type: 'application/json' });
    const url = URL.createObjectURL(blob);
    const anchor = document.createElement('a');
    anchor.href = url;
    anchor.download = 'management-api.openapi.json';
    anchor.click();
    URL.revokeObjectURL(url);
  };

  return (
    <div className={styles.page}>
      <div className="card">
        <h2>Management API</h2>
        <p className={styles.subtle}>
          Route catalog for the management listener. This list is the source for the generated OpenAPI document below.
        </p>
        <div className={styles.tableWrap}>
          <table className={styles.table}>
            <thead>
              <tr>
                <th>Method</th>
                <th>Path</th>
                <th>Purpose</th>
              </tr>
            </thead>
            <tbody>
              {MANAGEMENT_API_ROUTES.map(({ method, path, purpose }) => (
                <tr key={`${method}-${path}`}>
                  <td>
                    <span className={`badge ${methodBadgeClass(method)}`}>{method}</span>
                  </td>
                  <td className={styles.pathCell}>{path}</td>
                  <td className={styles.descCell}>{purpose}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>

      <div className="card">
        <h2>Swagger / OpenAPI</h2>
        <p className={styles.subtle}>
          Generated OpenAPI 3.0 JSON for the management API. Import this JSON into Swagger UI or any OpenAPI tooling.
        </p>
        <div className={styles.cardActions}>
          <button className="btn btn-primary" type="button" onClick={downloadOpenApi}>
            <i className="fas fa-download" /> Download openapi.json
          </button>
          <button className="btn" type="button" onClick={() => void navigator.clipboard.writeText(openapiJson)}>
            <i className="fas fa-copy" /> Copy JSON
          </button>
        </div>
        <div className={styles.codeWrap}>
          <pre className={styles.code}>{openapiJson}</pre>
        </div>
      </div>

      <div className="card">
        <h2>Interactive Swagger UI</h2>
        <p className={styles.subtle}>
          Interactive API documentation rendered from the generated OpenAPI spec.
        </p>
        <div className={styles.swaggerWrap}>
          <SwaggerUI spec={openapi} docExpansion="list" defaultModelsExpandDepth={-1} />
        </div>
      </div>
    </div>
  );
}
