# Pertisk eProxy - Erlang QUIC Reverse Proxy

A high-performance QUIC reverse proxy written in Erlang/OTP with HTTP/2 and HTTP/3 support, automatic certificate management via ACME/Let's Encrypt, and modern compression algorithms (Brotli, Zstd).

## Features

- **HTTP/2 and HTTP/3 Support**: Modern protocol support via QUIC
- **Reverse Proxy**: Route traffic to upstream servers
- **Auto ACME**: Automatic SSL/TLS certificate provisioning and renewal via Let's Encrypt
- **Compression**: Brotli and Zstd compression for optimized bandwidth usage
- **Admin Management**: RESTful API for managing upstream servers and configuration
- **High Performance**: Built on Erlang/OTP for concurrency and reliability

## Requirements

- Erlang/OTP 25+
- rebar3 build tool
- macOS, Linux, or other UNIX-like system

## Installation

```bash
# Clone the repository
git clone <repository-url>
cd pertisk-eproxy

# Build the project
rebar3 compile

# Build release
rebar3 release
```

## Configuration

### Main Configuration File: `config/sys.config`

```erlang
{pertisk_eproxy, [
  {listen_addr, "0.0.0.0"},      % Listen on all interfaces
  {listen_port_h2, 443},         % HTTP/2 port
  {listen_port_h3, 443},         % HTTP/3 port
  {admin_port, 8080},             % Admin API port
  {acme_enabled, true},           % Enable automatic ACME
  {acme_provider, "https://acme-v02.api.letsencrypt.org/directory"},
  {compression_methods, [brotli, zstd, gzip]}
]}
```

## Usage

### Development Mode

```bash
# Start the backend
make run

# In another terminal, start the admin UI
make admin-dev
```

The admin dashboard will be available at `http://localhost:3000`

### Production Release

```bash
# Build backend release
rebar3 as prod release
rebar3 as prod tar

# Build frontend
make admin-build

# Deploy the releases
tar -xzf _build/prod/rel/pertisk_eproxy.tar.gz -C /opt/
cp -r admin-ui/build /var/www/pertisk-admin
```

## Admin Dashboard

The project includes a modern React-based admin dashboard for managing the reverse proxy.

### Starting the Admin UI

```bash
# Development mode (with hot reload)
make admin-dev
# Opens at http://localhost:3000

# Production build
make admin-build
# Creates optimized build in admin-ui/build
```

### Features

- **Dashboard**: Real-time system status and statistics
- **Sites Management**: Add, view, and remove reverse proxy upstreams
- **Certificate Management**: Manage SSL/TLS certificates and ACME automation
- **Settings**: Configure proxy parameters, compression methods, and ACME provider

### Admin UI Architecture

- Built with React 18 and Tailwind CSS
- Uses Axios for API communication
- React Router for navigation
- Responsive design for mobile and desktop

See [admin-ui/README.md](admin-ui/README.md) for detailed documentation.

## Admin API

The admin interface runs on port 8080 (configurable) and provides REST endpoints:

### Get Status
```bash
curl http://localhost:8080/api/status
```

### List Upstreams
```bash
curl http://localhost:8080/api/upstreams
```

### Add Upstream
```bash
curl -X POST http://localhost:8080/api/upstreams \
  -H "Content-Type: application/json" \
  -d '{
    "name": "backend-1",
    "target": "192.168.1.100:8080",
    "health_check": "http://192.168.1.100:8080/health"
  }'
```

### Get Certificates
```bash
curl http://localhost:8080/api/certs
```

## Architecture

### Modules

- **pertisk_eproxy_app**: Application startup callback
- **pertisk_eproxy_sup**: Supervisor for child processes
- **pertisk_eproxy_proxy**: QUIC listener and request routing
- **pertisk_eproxy_admin**: REST API for management
- **pertisk_eproxy_acme**: ACME client for Let's Encrypt integration
- **pertisk_eproxy_compression**: Compression/decompression engine

### Supervision Tree

```
pertisk_eproxy_sup
├── pertisk_eproxy_acme (permanent)
├── pertisk_eproxy_compression (permanent)
├── pertisk_eproxy_admin (permanent)
└── pertisk_eproxy_proxy (permanent)
```

## ACME Configuration

### Enable Auto-ACME

Set in `config/sys.config`:
```erlang
{acme_enabled, true},
{acme_provider, "https://acme-v02.api.letsencrypt.org/directory"},
{acme_email, "admin@example.com"}
```

The system will:
1. Automatically request certificates for configured domains
2. Renew certificates 30 days before expiry
3. Validate domain ownership via HTTP-01, DNS-01, or TLS-ALPN-01 challenges
4. Store certificates securely

## Compression

The proxy automatically negotiates compression based on the `Accept-Encoding` header:

- **Brotli**: High compression ratio, best for text
- **Zstd**: Fast compression and decompression
- **Gzip**: Fallback, widely supported

## Building from Source

```bash
# Clean build
rebar3 clean

# Compile with tests
rebar3 do compile, eunit

# Generate documentation
rebar3 edoc

# Create distribution package
rebar3 as prod tar
```

## Testing

```bash
# Run unit tests
rebar3 eunit

# Run common test suites
rebar3 ct

# Run with coverage
rebar3 cover
```

## Performance Tuning

### VM Arguments (config/vm.args)

- **+S auto:auto**: Use all available CPU cores
- **+A 256**: Number of async threads
- **+K true**: Enable kernel poll

### Upstream Tuning

Configure in sys.config:
```erlang
{upstream_pool_size, 100},        % Connection pool size
{upstream_timeout, 30000},        % Timeout in ms
{upstream_keepalive, true}        % Keep-alive connections
```

## Troubleshooting

### Port Already in Use

```bash
# Find process using port
lsof -i :443

# Kill process
kill -9 <PID>
```

### Certificate Renewal Issues

Check logs:
```bash
tail -f ./_build/prod/rel/pertisk_eproxy/var/log/erlang.log.1
```

### Memory Issues

Increase heap in vm.args:
```
+hms 2097152  # Min heap size
+hml 67108864  # Max heap size
```

## License

Proprietary - Pertisk Technologies

## Contributing

Please submit pull requests and issues to the main repository.

## Support

For issues and questions, contact: support@pertisk.tech
