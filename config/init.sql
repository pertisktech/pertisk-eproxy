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

-- Sample data: example backend with two upstreams
INSERT OR REPLACE INTO backends (name, algorithm, health_path, health_interval_secs)
VALUES ('example-backend', 'round_robin', '/health', 30);

INSERT OR REPLACE INTO upstreams (backend_name, addr, weight)
VALUES 
    ('example-backend', '127.0.0.1:3000', 1),
    ('example-backend', '127.0.0.1:3001', 1);

-- Sample site routing to the backend
INSERT OR REPLACE INTO sites (host, backend)
VALUES ('example.localhost', 'example-backend');

INSERT OR REPLACE INTO path_rewrites (site_host, path, path_type, rewrite)
VALUES ('example.localhost', '/', 'prefix', NULL);
