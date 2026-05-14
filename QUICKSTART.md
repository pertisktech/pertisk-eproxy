# Pertisk eProxy - Complete Stack Deployment Guide

Welcome to Pertisk eProxy! This is a complete reverse proxy solution with automatic SSL/TLS certificate management, HTTP/3 support, and a modern admin dashboard.

## 🚀 Quick Start (5 minutes)

### Option 1: Using Make (Recommended for Development)

```bash
# Terminal 1: Start the backend
cd /Users/dotnetnat/projects/pertisk-tech/pertisk-eproxy
make run

# Terminal 2: Start the admin UI
cd /Users/dotnetnat/projects/pertisk-tech/pertisk-eproxy
make admin-dev
```

Then open your browser to:
- **Admin Dashboard**: http://localhost:3000
- **API**: http://localhost:8080/api

### Option 2: Using Docker Compose

```bash
cd /Users/dotnetnat/projects/pertisk-tech/pertisk-eproxy
docker-compose up
```

Access:
- **Admin Dashboard**: http://localhost:3000
- **API**: http://localhost:8080/api

### Option 3: Native Installation

```bash
# Backend
cd /Users/dotnetnat/projects/pertisk-tech/pertisk-eproxy
rebar3 compile
rebar3 shell
# In Erlang shell: application:start(pertisk_eproxy).

# Admin UI (new terminal)
cd /Users/dotnetnat/projects/pertisk-tech/pertisk-eproxy/admin-ui
npm install
npm start
```

## 📚 Documentation

### Backend (Erlang/OTP)
- [README.md](README.md) - Main documentation
- [DEVELOPMENT.md](DEVELOPMENT.md) - Development guide
- [ERLANG_QUIC_SETUP.md](ERLANG_QUIC_SETUP.md) - QUIC setup instructions

### Frontend (React)
- [admin-ui/README.md](admin-ui/README.md) - Admin UI documentation

### Integration
- [INTEGRATION.md](INTEGRATION.md) - Backend/frontend integration guide

## 🎯 Common Tasks

### Add a Reverse Proxy Site

1. Open Admin Dashboard: http://localhost:3000
2. Click "Sites" in the sidebar
3. Click "Add Site" button
4. Fill in the form:
   - **Site Name**: example.com
   - **Target Upstream**: 192.168.1.100:8080
   - **Health Check**: http://192.168.1.100:8080/health (optional)
   - **Weight**: 1
5. Click "Add Site"

### Request an SSL/TLS Certificate

1. Open http://localhost:3000/certificates
2. Click "Request Certificate" button
3. Enter domains (comma-separated):
   ```
   example.com, www.example.com, api.example.com
   ```
4. Click "Request Certificate"

The certificate will be automatically renewed 30 days before expiry.

### Configure ACME Settings

1. Open http://localhost:3000/settings
2. Enable "Automatic ACME (Let's Encrypt)"
3. Set ACME provider (default: Let's Encrypt production)
4. Enter admin email for notifications
5. Click "Save Settings"

### Test the Proxy

```bash
# Test with curl (if you have a site configured)
curl -k https://localhost:443/ \
  -H "Host: example.com"

# Or use the API directly
curl http://localhost:8080/api/status
```

## 📦 Project Structure

```
pertisk-eproxy/
├── src/                              # Erlang backend
│   ├── pertisk_eproxy_app.erl       # Application entry
│   ├── pertisk_eproxy_sup.erl       # Supervisor
│   ├── pertisk_eproxy_proxy.erl     # QUIC proxy
│   ├── pertisk_eproxy_admin.erl     # Admin logic
│   ├── pertisk_eproxy_admin_handler.erl  # HTTP handlers
│   ├── pertisk_eproxy_acme.erl      # ACME client
│   └── pertisk_eproxy_compression.erl # Compression
├── admin-ui/                         # React frontend
│   ├── public/
│   ├── src/
│   │   ├── api/client.js            # API client
│   │   ├── components/Layout.js     # Main layout
│   │   └── pages/                   # Dashboard, Sites, Certs, Settings
│   └── package.json
├── config/                           # Configuration
│   ├── sys.config                   # Runtime config
│   └── vm.args                      # VM arguments
├── test/                             # Tests
├── rebar.config                      # Build config
├── Makefile                          # Build targets
├── README.md                         # Documentation
├── DEVELOPMENT.md                    # Dev guide
├── INTEGRATION.md                    # Integration guide
└── docker-compose.yml               # Docker setup
```

## 🔧 Available Make Commands

```bash
# Backend
make build              # Compile Erlang project
make run                # Compile and start shell
make test               # Run tests
make release            # Build production release

# Frontend
make admin-install      # Install npm dependencies
make admin-dev          # Start dev server
make admin-build        # Build for production

# Other
make clean              # Clean build artifacts
make help               # Show all commands
```

## 🚢 Production Deployment

### Build Releases

```bash
# Backend release
rebar3 as prod release
rebar3 as prod tar

# Frontend build
make admin-build
```

### Deploy with Systemd

Create `/etc/systemd/system/pertisk-eproxy.service`:

```ini
[Unit]
Description=Pertisk eProxy Reverse Proxy
After=network.target

[Service]
Type=forking
User=pertisk
WorkingDirectory=/opt/pertisk-eproxy
ExecStart=/opt/pertisk-eproxy/bin/pertisk_eproxy start
ExecStop=/opt/pertisk-eproxy/bin/pertisk_eproxy stop
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

Then:

```bash
systemctl enable pertisk-eproxy
systemctl start pertisk-eproxy
systemctl status pertisk-eproxy
```

### Deploy with Docker

```bash
docker build -t pertisk-eproxy-backend .
docker build -t pertisk-eproxy-admin ./admin-ui

docker run -d \
  --name pertisk-backend \
  -p 8080:8080 \
  -p 443:443 \
  -v /etc/pertisk:/etc/pertisk \
  pertisk-eproxy-backend

docker run -d \
  --name pertisk-admin \
  -p 3000:3000 \
  -e REACT_APP_API_URL=http://backend:8080/api \
  pertisk-eproxy-admin
```

## 🔐 Security Considerations

1. **Use HTTPS in Production**: Configure real SSL certificates
2. **Firewall Rules**: Restrict access to admin ports
3. **Authentication**: Add JWT or OAuth for admin panel
4. **Rate Limiting**: Protect API endpoints from abuse
5. **Monitoring**: Set up alerts for certificate expiry
6. **Backups**: Backup certificate and configuration files

## 🐛 Troubleshooting

### Backend won't start

```bash
# Check if port is already in use
lsof -i :8080
lsof -i :443

# Try killing existing process
kill -9 <PID>

# Restart
make run
```

### Admin UI shows "Connection Error"

- Make sure backend is running: `make run`
- Check API endpoint: `curl http://localhost:8080/api/status`
- Verify firewall allows connections

### Certificates not renewing

1. Check ACME is enabled in Settings
2. Verify domains are correctly configured
3. Check backend logs for ACME errors
4. Ensure system time is correct (ACME is time-sensitive)

## 📞 Support

- **Email**: support@pertisk.tech
- **Docs**: See README.md, DEVELOPMENT.md, INTEGRATION.md
- **Issues**: Check the GitHub repository

## 📝 Changelog

### v0.1.0 (2025-05-14)
- Initial release
- Erlang QUIC reverse proxy
- React admin dashboard
- ACME Let's Encrypt support
- Compression support (gzip)
- Docker support

## 📄 License

Proprietary - Pertisk Technologies

---

**Ready to deploy?** Start with `make run` and `make admin-dev`, then open http://localhost:3000! 🎉
