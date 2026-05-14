# Admin UI and Backend Integration

This document describes how the React admin dashboard integrates with the Erlang backend.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                    Client Browser                           │
├─────────────────────────────────────────────────────────────┤
│                 React Admin UI (port 3000)                  │
│  - Dashboard   - Sites   - Certificates   - Settings        │
└──────────────────────────┬──────────────────────────────────┘
                           │ HTTP/HTTPS
                           │ REST API
                           ▼
┌─────────────────────────────────────────────────────────────┐
│              Erlang Backend (port 8080)                     │
├─────────────────────────────────────────────────────────────┤
│   Admin API Handler (pertisk_eproxy_admin_handler.erl)      │
│   - Status endpoints    - Upstream management              │
│   - Certificate info    - Health checks                    │
└──────────────────────────┬──────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│     Core Services (Supervisor Tree)                        │
├─────────────────────────────────────────────────────────────┤
│ - ACME Client        - Compression Engine                  │
│ - Admin Manager      - QUIC Proxy                          │
└─────────────────────────────────────────────────────────────┘
```

## API Endpoints

### Status
```
GET /api/status
Response: {
  "upstreams_count": 2,
  "admin_port": 8080,
  "compression_methods": ["brotli", "zstd", "gzip"],
  "acme_enabled": true
}
```

### Upstreams Management
```
GET /api/upstreams
Response: {
  "upstreams": [
    {
      "host": "api.example.com",
      "config": {
        "target": "192.168.1.100:8080",
        "weight": 1,
        "health_check": "http://192.168.1.100:8080/health"
      }
    }
  ]
}

POST /api/upstreams
Request: {
  "name": "api.example.com",
  "target": "192.168.1.100:8080",
  "health_check": "http://192.168.1.100:8080/health",
  "weight": 1
}
Response: {
  "status": "ok",
  "host": "api.example.com"
}

DELETE /api/upstreams/:host
Response: {
  "status": "removed",
  "host": "api.example.com"
}
```

### Certificates
```
GET /api/certs
Response: {
  "total": 3,
  "expiring_soon": [],
  "issued": [
    {
      "domain": "example.com",
      "issued_at": "2025-01-15",
      "expires_at": "2026-01-15"
    }
  ]
}

POST /api/certs/request (Not yet implemented)
Request: {
  "domains": ["example.com", "www.example.com"]
}
```

## Development Workflow

### Starting Development Environment

Terminal 1 - Start the Erlang backend:
```bash
make run
```

Terminal 2 - Start the React UI:
```bash
make admin-dev
```

This will:
1. Start the Erlang backend on `http://localhost:8080` (API) and port 443 (proxy)
2. Start the React dev server on `http://localhost:3000`
3. Enable hot reload for React changes

### Backend Development

When modifying backend code:
1. Edit files in `src/`
2. Recompile: `rebar3 compile`
3. Changes take effect after restarting the shell

### Frontend Development

When modifying frontend code:
1. Edit files in `admin-ui/src/`
2. Changes auto-reload in browser
3. Check console for errors

## API Client Usage

The `src/api/client.js` provides a configured Axios client:

```javascript
import { getUpstreams, addUpstream, removeUpstream } from '../api/client';

// Get all upstreams
const upstreams = await getUpstreams();

// Add new upstream
await addUpstream({
  name: 'api.example.com',
  target: '192.168.1.100:8080',
  health_check: 'http://192.168.1.100:8080/health',
  weight: 1
});

// Remove upstream
await removeUpstream('api.example.com');
```

## Error Handling

### Connection Errors

If the backend is not running, the UI displays:
```
Connection Error
Unable to connect to the API. Make sure the eProxy server is running on localhost:8080
```

Solution: Start the backend with `make run`

### CORS Issues

If you see CORS errors in browser console, add CORS headers to the Erlang handler:

```erlang
Resp = cowboy_req:reply(
    200,
    #{<<"content-type">> => <<"application/json">>,
      <<"access-control-allow-origin">> => <<"*">>,
      <<"access-control-allow-methods">> => <<"GET, POST, PUT, DELETE">>,
      <<"access-control-allow-headers">> => <<"content-type">>},
    Body,
    Req
)
```

## Deployment

### Docker Compose

Run both services together:
```bash
docker-compose up
```

Access:
- Admin UI: http://localhost:3000
- API: http://localhost:8080/api

### Kubernetes

Deploy frontend and backend separately:

```yaml
# backend-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pertisk-eproxy-backend
spec:
  replicas: 1
  template:
    spec:
      containers:
      - name: backend
        image: pertisk/eproxy-backend:latest
        ports:
        - containerPort: 8080
        - containerPort: 443

---
# frontend-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pertisk-eproxy-admin
spec:
  replicas: 1
  template:
    spec:
      containers:
      - name: admin
        image: pertisk/eproxy-admin:latest
        ports:
        - containerPort: 3000
        env:
        - name: REACT_APP_API_URL
          value: "http://backend:8080/api"
```

## Performance Considerations

### Frontend
- Lazy load pages with React.lazy()
- Implement caching in API client
- Use React.memo for expensive components
- Monitor bundle size

### Backend
- Response times < 100ms for API calls
- Handle concurrent requests efficiently (Erlang/OTP)
- Cache frequently accessed data
- Consider rate limiting for admin endpoints

## Security Considerations

1. **Authentication**: Consider adding JWT tokens for API endpoints
2. **HTTPS**: Always use HTTPS in production
3. **CORS**: Restrict CORS origins to trusted domains
4. **Input Validation**: Validate all user inputs on backend
5. **Rate Limiting**: Implement rate limiting on admin API

## Monitoring

### Backend Metrics
```erlang
% In erlang shell
erlang:memory().              % Memory usage
erlang:processes_info().      % Process info
supervisor:which_children(pertisk_eproxy_sup).  % Child processes
```

### Frontend Monitoring
- Browser DevTools Network tab
- React DevTools extension
- Error tracking (e.g., Sentry)

## Testing

### Backend Tests
```bash
rebar3 eunit
rebar3 ct
```

### Frontend Tests
```bash
npm test
npm run build
```

## Troubleshooting

### Issue: API calls timeout

**Solution**: Check if backend is running
```bash
curl http://localhost:8080/api/status
```

### Issue: Upstreams not being added

**Solution**: Check backend logs and ensure valid format
```erlang
(pertisk_eproxy@localhost)1> pertisk_eproxy_admin:list_upstreams().
```

### Issue: React app shows blank screen

**Solution**: Check browser console for JavaScript errors
- Open DevTools (F12)
- Check Console tab for errors
- Verify API endpoint in .env file

## Future Enhancements

- [ ] WebSocket for real-time updates
- [ ] User authentication and authorization
- [ ] Audit logging
- [ ] Metrics dashboard (CPU, memory, requests/sec)
- [ ] Load balancing visualization
- [ ] Certificate renewal notifications
- [ ] Advanced routing rules
- [ ] Rate limiting configuration

## Support

For issues and questions:
- Email: support@pertisk.tech
- GitHub Issues: [repository-url]
- Documentation: See README.md and DEVELOPMENT.md
