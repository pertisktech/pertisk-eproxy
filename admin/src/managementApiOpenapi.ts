import { MANAGEMENT_API_ROUTES } from '@/managementApiRoutes';

type OpenApiSchema = {
  openapi: string;
  info: {
    title: string;
    version: string;
    description: string;
  };
  servers: Array<{ url: string }>;
  tags: Array<{ name: string; description: string }>;
  paths: Record<string, Record<string, unknown>>;
};

function toOpenApiPath(path: string): string {
  return path.replace(/:([a-zA-Z0-9_]+)/g, '{$1}');
}

function toTag(path: string): string {
  const parts = path.split('/').filter(Boolean);
  return parts[1] ?? 'general';
}

function operationId(method: string, path: string): string {
  const cleaned = path
    .replace(/\//g, '_')
    .replace(/[:{}]/g, '')
    .replace(/_+/g, '_')
    .replace(/^_/, '');
  return `${method.toLowerCase()}_${cleaned}`;
}

const TAG_DESCRIPTIONS: Record<string, string> = {
  admin: 'Administration operations',
  auth: 'Authentication and session operations',
  backup: 'Backup and restore operations',
  backends: 'Backend and upstream operations',
  certificates: 'TLS certificate operations',
  config: 'Runtime configuration operations',
  'dns-providers': 'DNS provider operations',
  health: 'Health check operations',
  helm: 'Helm integration operations',
  logs: 'Access log operations',
  management: 'Runtime node and process information',
  metrics: 'Prometheus metrics endpoint',
  realtime: 'Realtime WebSocket stream',
  reload: 'Configuration reload operation',
  sites: 'Site and routing operations',
  stats: 'Statistics snapshot operations',
  tls: 'TLS listener operations',
  version: 'Application version operations',
};

export function buildManagementOpenApi(appVersion: string): OpenApiSchema {
  const paths: OpenApiSchema['paths'] = {};
  const tagsSeen = new Set<string>();

  for (const route of MANAGEMENT_API_ROUTES) {
    const normalizedPath = toOpenApiPath(route.path);
    const methodKey = route.method.toLowerCase();
    const tag = toTag(route.path);
    const params = [...normalizedPath.matchAll(/\{([a-zA-Z0-9_]+)\}/g)].map((match) => ({
      name: match[1],
      in: 'path',
      required: true,
      schema: { type: 'string' },
    }));

    tagsSeen.add(tag);

    if (!paths[normalizedPath]) {
      paths[normalizedPath] = {};
    }

    paths[normalizedPath][methodKey] = {
      tags: [tag],
      summary: route.purpose,
      operationId: operationId(route.method, normalizedPath),
      parameters: params,
      responses: {
        '200': { description: 'Success' },
      },
    };
  }

  const tags = [...tagsSeen]
    .sort((a, b) => a.localeCompare(b))
    .map((name) => ({ name, description: TAG_DESCRIPTIONS[name] ?? 'Management API operations' }));

  return {
    openapi: '3.0.3',
    info: {
      title: 'pertisk-eproxy Management API',
      version: appVersion || '0.0.0',
      description: 'Generated OpenAPI definition from the admin route catalog.',
    },
    servers: [{ url: 'http://127.0.0.1:9080' }],
    tags,
    paths,
  };
}
