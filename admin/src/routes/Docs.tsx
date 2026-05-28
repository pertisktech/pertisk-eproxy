import { useMemo } from 'react';
import { buildManagementOpenApi } from '@/managementApiOpenapi';
import SwaggerUI from 'swagger-ui-react';
import 'swagger-ui-react/swagger-ui.css';
import styles from './Docs.module.css';

function getVersionLabel(): string {
  const v = import.meta.env?.VITE_APP_VERSION as string | undefined;
  if (!v) return '0.0.0';
  return v.startsWith('v') ? v.slice(1) : v;
}

export default function Docs() {
  const openapi = useMemo(() => buildManagementOpenApi(getVersionLabel()), []);

  return (
    <div className={styles.swaggerPage}>
      <SwaggerUI spec={openapi} docExpansion="list" defaultModelsExpandDepth={-1} />
    </div>
  );
}
