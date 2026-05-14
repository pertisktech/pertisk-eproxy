# Pertisk eProxy Development Guide

## Project Overview

Erlang QUIC reverse proxy with HTTP/2, HTTP/3, auto ACME, and compression support.

## Key Technologies

- **Erlang/OTP**: Concurrent, distributed runtime
- **QUIC**: Modern, low-latency protocol
- **Cowboy**: Web framework for admin API
- **erlang_quic**: QUIC protocol implementation
- **Brotli/Zstd**: Modern compression algorithms

## Development Workflow

### Building the Project
```bash
rebar3 compile
```

### Running in Development
```bash
rebar3 shell
(pertisk_eproxy@localhost)1> application:start(pertisk_eproxy).
```

### Testing
```bash
rebar3 eunit
rebar3 ct
```

## Module Structure

| Module | Purpose |
|--------|---------|
| `pertisk_eproxy_app` | Application lifecycle (start/stop) |
| `pertisk_eproxy_sup` | Supervisor tree management |
| `pertisk_eproxy_proxy` | QUIC listener and request routing |
| `pertisk_eproxy_admin` | REST API for management |
| `pertisk_eproxy_acme` | Let's Encrypt integration |
| `pertisk_eproxy_compression` | Brotli/Zstd compression |

## Key Features Implementation

### 1. HTTP/2 & HTTP/3 Support
- Integration with erlang_quic library
- ALPN negotiation for protocol selection
- Request/response handling in `pertisk_eproxy_proxy`

### 2. Admin Management API
- Cowboy-based REST API on port 8080
- Endpoints:
  - `GET /api/status` - System status
  - `GET /api/upstreams` - List configured upstreams
  - `POST /api/upstreams` - Add upstream
  - `DELETE /api/upstreams/:host` - Remove upstream
  - `GET /api/certs` - Certificate information

### 3. Auto ACME (Let's Encrypt)
- Automatic certificate request and renewal
- Support for HTTP-01, DNS-01, TLS-ALPN-01 challenges
- Renewal check every 24 hours
- Renewal 30 days before expiry

### 4. Compression Support
- Automatic negotiation via Accept-Encoding header
- Brotli: High ratio, best for text (quality 11)
- Zstd: Fast, good compression (level 19)
- Gzip: Fallback option

## Common Development Tasks

### Adding a New Upstream Server
```erlang
pertisk_eproxy_admin:add_upstream(
  <<"api.example.com">>,
  #{
    target => "192.168.1.100:8080",
    health_check => "http://192.168.1.100:8080/health",
    weight => 1
  }
).
```

### Requesting a Certificate
```erlang
pertisk_eproxy_acme:request_certificate([
  "example.com",
  "www.example.com"
]).
```

### Checking System Status
```erlang
pertisk_eproxy_admin:get_status().
```

## Configuration

Edit `config/sys.config` to customize:
- Listen addresses and ports
- ACME provider and settings
- Compression methods
- Upstream servers

## Performance Considerations

- Erlang/OTP handles thousands of concurrent connections
- QUIC provides lower latency than TCP+TLS
- Connection pooling to upstream servers
- Compression reduces bandwidth usage
- Memory footprint scales with active connections

## Debugging

### Enable Debug Logging
In Erlang shell:
```erlang
logger:set_primary_config(level, debug).
```

### Profile Memory Usage
```erlang
observer:start().
```

### Check Running Processes
```erlang
erlang:processes().
supervisor:which_children(pertisk_eproxy_sup).
```

## Next Steps

1. Integrate with actual erlang_quic library streams
2. Implement HTTP/2 SETTINGS frame handling
3. Add load balancing algorithms
4. Implement rate limiting
5. Add metrics and monitoring
6. Create administrative dashboard
