# Hot-reload configuration

Reload proxy JSON from disk without restarting the BEAM.

## Proxy mode

```bash
curl -X POST http://127.0.0.1:9080/api/reload
```

Re-reads the file at `config_file` in `sys.config` (default `config/proxy.json`).
Existing proxy connections are kept.

Admin UI: **Settings → Reload Config**.

## Ingress mode

Listener settings come from `ingress.json` (Helm `controller.config`). After
`helm upgrade`, restart pods or roll the deployment so the ConfigMap is remounted.

Kubernetes routes update automatically from the ingress watcher — no reload API
needed for Ingress changes.

## Full config replace

```bash
curl -X PUT http://127.0.0.1:9080/api/config \
  -H 'Content-Type: application/json' \
  -d @config/proxy.json
```

Requires authentication when `admin_auth` is `local`.
