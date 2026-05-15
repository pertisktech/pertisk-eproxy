/**
 * Supported DNS provider field definitions (aligned with pertisk-rproxy
 * `supported_dns_providers()` in src/api/mod.rs) for the admin UI.
 * eProxy runs ACME DNS-01 automatically when provider type is `cloudflare`, the site
 * uses Auto SSL (DNS-01 + contact email, no certificate label yet), and
 * `{acme_terms_agreed, true}` is set in sys.config (see also `acme_directory_url`).
 */

export interface SupportedDnsFieldDef {
  key: string;
  label: string;
  type: string;
  required: boolean;
}

export interface SupportedDnsProviderDef {
  id: string;
  name: string;
  fields: SupportedDnsFieldDef[];
}

export const SUPPORTED_DNS_PROVIDERS: SupportedDnsProviderDef[] = [
  {
    id: 'cloudflare',
    name: 'Cloudflare',
    fields: [
      { key: 'api_token', label: 'API Token', type: 'password', required: true },
      { key: 'zone_id', label: 'Zone ID (optional)', type: 'text', required: false },
    ],
  },
  {
    id: 'digitalocean',
    name: 'DigitalOcean',
    fields: [{ key: 'api_token', label: 'API Token', type: 'password', required: true }],
  },
  {
    id: 'route53',
    name: 'AWS Route 53',
    fields: [
      { key: 'access_key_id', label: 'Access Key ID', type: 'text', required: true },
      { key: 'secret_access_key', label: 'Secret Access Key', type: 'password', required: true },
      { key: 'session_token', label: 'Session Token (optional)', type: 'password', required: false },
      { key: 'region', label: 'Region (optional, default us-east-1)', type: 'text', required: false },
      { key: 'zone_id', label: 'Hosted Zone ID (optional)', type: 'text', required: false },
      { key: 'zone_name', label: 'Zone Name (optional)', type: 'text', required: false },
    ],
  },
  {
    id: 'godaddy',
    name: 'GoDaddy',
    fields: [
      { key: 'api_key', label: 'API Key', type: 'text', required: true },
      { key: 'api_secret', label: 'API Secret', type: 'password', required: true },
    ],
  },
  {
    id: 'linode',
    name: 'Linode',
    fields: [{ key: 'api_token', label: 'API Token', type: 'password', required: true }],
  },
  {
    id: 'hetzner',
    name: 'Hetzner DNS',
    fields: [{ key: 'api_token', label: 'API Token', type: 'password', required: true }],
  },
  {
    id: 'duckdns',
    name: 'DuckDNS',
    fields: [
      { key: 'domain', label: 'Subdomain', type: 'text', required: true },
      { key: 'token', label: 'Token', type: 'password', required: true },
    ],
  },
  {
    id: 'namecheap',
    name: 'Namecheap',
    fields: [
      { key: 'api_user', label: 'API User', type: 'text', required: true },
      { key: 'api_key', label: 'API Key', type: 'password', required: true },
      { key: 'username', label: 'Username', type: 'text', required: true },
      { key: 'client_ip', label: 'Client IP', type: 'text', required: true },
      { key: 'domain', label: 'Domain', type: 'text', required: true },
    ],
  },
  {
    id: 'ovh',
    name: 'OVH',
    fields: [
      { key: 'application_key', label: 'Application Key', type: 'text', required: true },
      { key: 'application_secret', label: 'Application Secret', type: 'password', required: true },
      { key: 'consumer_key', label: 'Consumer Key', type: 'password', required: true },
    ],
  },
  {
    id: 'googleclouddns',
    name: 'Google Cloud DNS',
    fields: [
      { key: 'project_id', label: 'Project ID', type: 'text', required: true },
      { key: 'service_account_json', label: 'Service Account JSON', type: 'textarea', required: true },
      { key: 'managed_zone', label: 'Managed Zone (optional)', type: 'text', required: false },
    ],
  },
  {
    id: 'azure',
    name: 'Azure DNS',
    fields: [
      { key: 'tenant_id', label: 'Tenant ID', type: 'text', required: true },
      { key: 'client_id', label: 'Client ID', type: 'text', required: true },
      { key: 'client_secret', label: 'Client Secret', type: 'password', required: true },
      { key: 'subscription_id', label: 'Subscription ID', type: 'text', required: true },
      { key: 'resource_group', label: 'Resource Group', type: 'text', required: true },
      { key: 'zone_name', label: 'Zone Name', type: 'text', required: true },
    ],
  },
  {
    id: 'gandi',
    name: 'Gandi',
    fields: [{ key: 'api_token', label: 'API Token', type: 'password', required: true }],
  },
  {
    id: 'manual',
    name: 'Manual',
    fields: [],
  },
  {
    id: 'label',
    name: 'Simple label (name only)',
    fields: [],
  },
];