/**
 * Supported DNS provider field definitions (aligned with pertisk-rproxy
 * `supported_dns_providers()` in src/api/mod.rs) for the admin UI.
 * eProxy runs ACME DNS-01 automatically when provider type is `cloudflare`,
 * `digitalocean`, `vultr`, `porkbun`, `linode`, `hetzner`, `desec`, `gandi`, `powerdns`, or `duckdns`, and the site
 * uses Auto SSL (DNS-01 + contact email, no certificate label yet), and
 * `{acme_terms_agreed, true}` is set in sys.config (see also `acme_directory_url`).
 *
 * Runtime ACME DNS-01 issuance supports all providers listed below.
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
    fields: [
      { key: 'api_token', label: 'API Token', type: 'password', required: true },
      { key: 'domain', label: 'Domain (optional)', type: 'text', required: false },
    ],
  },
  {
    id: 'hetzner',
    name: 'Hetzner DNS',
    fields: [
      { key: 'api_token', label: 'API Token', type: 'password', required: true },
      { key: 'domain', label: 'Domain (optional)', type: 'text', required: false },
    ],
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
    fields: [
      { key: 'api_token', label: 'API Token', type: 'password', required: true },
      { key: 'domain', label: 'Domain (optional)', type: 'text', required: false },
    ],
  },
  {
    id: 'vultr',
    name: 'Vultr DNS',
    fields: [
      { key: 'api_token', label: 'API Token', type: 'password', required: true },
      { key: 'zone_name', label: 'Zone Name (optional)', type: 'text', required: false },
    ],
  },
  {
    id: 'porkbun',
    name: 'Porkbun',
    fields: [
      { key: 'api_key', label: 'API Key', type: 'text', required: true },
      { key: 'secret_api_key', label: 'Secret API Key', type: 'password', required: true },
      { key: 'domain', label: 'Domain (optional)', type: 'text', required: false },
    ],
  },
  {
    id: 'desec',
    name: 'deSEC',
    fields: [
      { key: 'api_token', label: 'API Token', type: 'password', required: true },
      { key: 'domain', label: 'Domain (optional)', type: 'text', required: false },
    ],
  },
  {
    id: 'powerdns',
    name: 'PowerDNS',
    fields: [
      { key: 'api_url', label: 'API URL', type: 'text', required: true },
      { key: 'api_key', label: 'API Key', type: 'password', required: true },
      { key: 'server_id', label: 'Server ID (optional, default localhost)', type: 'text', required: false },
      { key: 'zone_name', label: 'Zone Name (optional)', type: 'text', required: false },
    ],
  },
  {
    id: 'rfc2136',
    name: 'RFC2136 (BIND / TSIG)',
    fields: [
      { key: 'nameserver', label: 'Nameserver (host:port)', type: 'text', required: true },
      { key: 'tsig_key_name', label: 'TSIG Key Name', type: 'text', required: true },
      { key: 'tsig_secret', label: 'TSIG Secret', type: 'password', required: true },
      { key: 'tsig_algorithm', label: 'TSIG Algorithm (optional)', type: 'text', required: false },
    ],
  },
  {
    id: 'cloudns',
    name: 'ClouDNS',
    fields: [
      { key: 'auth_id', label: 'Auth ID', type: 'text', required: true },
      { key: 'auth_password', label: 'Auth Password', type: 'password', required: true },
    ],
  },
  {
    id: 'easydns',
    name: 'EasyDNS',
    fields: [
      { key: 'token', label: 'Token', type: 'text', required: true },
      { key: 'key', label: 'Key', type: 'password', required: true },
    ],
  },
  {
    id: 'dnsmadeeasy',
    name: 'DNS Made Easy',
    fields: [
      { key: 'api_key', label: 'API Key', type: 'text', required: true },
      { key: 'secret_key', label: 'Secret Key', type: 'password', required: true },
    ],
  },
  {
    id: 'dynu',
    name: 'Dynu',
    fields: [{ key: 'api_token', label: 'API Token', type: 'password', required: true }],
  },
  {
    id: 'customlego',
    name: 'Custom (Lego DNS)',
    fields: [
      { key: 'lego_provider', label: 'Lego Provider Name (e.g. alidns)', type: 'text', required: true },
      {
        key: 'env_vars_json',
        label: 'Lego Env Vars JSON (e.g. {"ALICLOUD_ACCESS_KEY":"..."})',
        type: 'textarea',
        required: true,
      },
    ],
  },
];