# RPM deploy and SQLite (`data/proxy.db`)

## Model (no automatic backup)

| `data/proxy.db` | On service start |
|-----------------|------------------|
| **Exists** | `migrate_schema` only (`CREATE TABLE IF NOT EXISTS`) — config loaded from SQLite |
| **Missing** | First deploy: create DB + seed once from `config/proxy.json` |

The RPM **does not** ship `data/` or `proxy.db`, so upgrades do not overwrite your database.

`config/proxy.json` is only used for the **first** empty install. After that, change sites/backends in the admin UI (stored in SQLite).

## RPM install

- **Postinstall:** creates `data/acme`, `data/tls`, `log` only.
- **Preinstall:** creates system user/group only (no DB backup).

## Logs

- Upgrade: `SQLite migrate at data/proxy.db (existing database)`
- First install: `SQLite data/proxy.db not found yet` then `First deploy: seeding SQLite from config/proxy.json`

## Optional manual backup

Only if you want extra safety before an upgrade:

```bash
sudo systemctl stop pertisk-eproxy
sudo cp -a /opt/pertisk-eproxy/data/proxy.db ~/proxy.db.manual.bak
```

Or `GET /api/backup/export` while the service is running.

## Mnesia → SQLite (one-time)

Old installs used `data/mnesia/`. Postinstall may move it to `data/mnesia.bak`. SQLite does not import Mnesia data automatically.

## OpenSSL / ports

See earlier sections in this file for `LD_LIBRARY_PATH`, `CAP_NET_BIND_SERVICE`, and QUIC build notes.
