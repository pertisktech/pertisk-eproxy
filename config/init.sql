-- SQLite database schema for pertisk_eproxy (proxy-only mode)

CREATE TABLE IF NOT EXISTS backends (
    name TEXT PRIMARY KEY,
    algorithm TEXT NOT NULL,
    health_path TEXT,
    health_interval_secs INTEGER DEFAULT 30
);

CREATE TABLE IF NOT EXISTS upstreams (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    backend_name TEXT NOT NULL,
    addr TEXT NOT NULL,
    weight INTEGER DEFAULT 1,
    FOREIGN KEY(backend_name) REFERENCES backends(name)
);

CREATE TABLE IF NOT EXISTS sites (
    host TEXT PRIMARY KEY,
    backend TEXT NOT NULL,
    FOREIGN KEY(backend) REFERENCES backends(name)
);

CREATE TABLE IF NOT EXISTS path_rewrites (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    site_host TEXT NOT NULL,
    path TEXT NOT NULL,
    path_type TEXT DEFAULT 'prefix',
    rewrite TEXT,
    FOREIGN KEY(site_host) REFERENCES sites(host)
);

CREATE TABLE IF NOT EXISTS certificates (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL UNIQUE
);

CREATE TABLE IF NOT EXISTS dns_providers (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL UNIQUE,
    provider_type TEXT NOT NULL,
    credentials_json TEXT NOT NULL DEFAULT '{}'
);
