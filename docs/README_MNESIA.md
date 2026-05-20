# Mnesia storage (pertisk_eproxy)

Runtime configuration, TLS certificate metadata, DNS providers, and local admin users are stored in **Mnesia** (OTP built-in DB).

## Directory

Set in `config/sys.config`:

```erlang
{mnesia_dir, "data/mnesia"}.
```

Legacy `{db_file, "data/mnesia"}` is still read for compatibility; prefer `{mnesia_dir, "data/mnesia"}`.

On first start with an empty database, the app loads `config/proxy.json` and persists the full config into Mnesia (`runtime_config` + `sites` projection).

## Tables

| Table | Purpose |
|-------|---------|
| `pertisk_eproxy_runtime_state` | Full proxy config term (base64 Erlang map) |
| `pertisk_eproxy_site` | Per-host projection (routes as JSON) |
| `pertisk_eproxy_certificate` | Cert rows (PEM in DB or ACME paths on disk) |
| `pertisk_eproxy_dns_provider` | DNS-01 provider credentials |
| `pertisk_eproxy_admin_user` | Local admin password hashes |
| `pertisk_eproxy_counter` | Auto-increment ids |

Schema setup: `src/pertisk_eproxy_mnesia.erl`. CRUD API: `src/pertisk_eproxy_db.erl`.

## Shell inspection

```bash
rebar3 shell
```

```erlang
application:set_env(pertisk_eproxy, mnesia_dir, "data/mnesia").
pertisk_eproxy_db:init("data/mnesia").
mnesia:info().
mnesia:dirty_read(pertisk_eproxy_runtime_state, runtime_config).
```

## Migration / Reset

There is no automatic import path from older storage formats. Options:

1. **Re-seed from JSON** — stop the app, remove `data/mnesia/`, ensure `config/proxy.json` is current, restart (default bootstrap path).
2. **Manual re-entry** — re-enter certs/DNS through the admin API or ACME flow.

## References

- [Mnesia User's Guide](https://www.erlang.org/doc/apps/mnesia/mnesia.html)
- [Getting Started](https://www.erlang.org/doc/apps/mnesia/mnesia_chap2.html)
