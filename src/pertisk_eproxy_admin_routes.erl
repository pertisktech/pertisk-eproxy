%% @doc Admin REST route table (shared by Cowboy management listener and HTTP/3 local dispatch).
-module(pertisk_eproxy_admin_routes).

-export([api_routes/0, dispatch/0, management_ui_routes/0, management_dispatch/0]).

-spec api_routes() -> [cowboy_router:route_path()].
api_routes() ->
    [
        {"/api/version", pertisk_eproxy_admin_handler, version},
        {"/api/proto", pertisk_eproxy_admin_handler, proto},
        {"/api/management", pertisk_eproxy_admin_handler, management},
        {"/api/stats", pertisk_eproxy_admin_handler, stats},
        {"/api/realtime", pertisk_eproxy_admin_ws_handler, realtime},
        {"/api/realtime-sse", pertisk_eproxy_admin_sse_handler, []},
        {"/api/logs", pertisk_eproxy_admin_handler, logs},
        {"/api/auth/config", pertisk_eproxy_admin_handler, auth_config},
        {"/api/auth/login", pertisk_eproxy_admin_handler, auth_login},
        {"/api/auth/refresh", pertisk_eproxy_admin_handler, auth_refresh},
        {"/api/auth/check", pertisk_eproxy_admin_handler, auth_check},
        {"/api/auth/logout", pertisk_eproxy_admin_handler, auth_logout},
        {"/api/admin/change-password", pertisk_eproxy_admin_handler, admin_change_password},
        {"/api/admin/api-token", pertisk_eproxy_admin_handler, admin_api_token},
        {"/api/backup/export", pertisk_eproxy_admin_handler, backup_export},
        {"/api/backup/restore", pertisk_eproxy_admin_handler, backup_restore},
        {"/api/helm/history", pertisk_eproxy_admin_handler, helm_history},
        {"/api/helm/values/:revision", pertisk_eproxy_admin_handler, helm_values},
        {"/api/certificates", pertisk_eproxy_admin_handler, certificates},
        {"/api/certificates/import", pertisk_eproxy_admin_handler, certificates_import},
        {"/api/certificates/:id/import", pertisk_eproxy_admin_handler, certificate_import},
        {"/api/certificates/:id", pertisk_eproxy_admin_handler, certificate},
        {"/api/certificates/:id/renew", pertisk_eproxy_admin_handler, certificate_renew},
        {"/api/dns-providers", pertisk_eproxy_admin_handler, dns_providers},
        {"/api/dns-providers/validate", pertisk_eproxy_admin_handler, dns_provider_validate},
        {"/api/dns-providers/:id", pertisk_eproxy_admin_handler, dns_provider},
        {"/api/tls/listener", pertisk_eproxy_admin_handler, tls_listener},
        {"/api/config", pertisk_eproxy_admin_handler, config},
        {"/api/backends", pertisk_eproxy_admin_handler, backends},
        {"/api/backends/:name", pertisk_eproxy_admin_handler, backend},
        {"/api/sites", pertisk_eproxy_admin_handler, sites},
        {"/api/sites/:host", pertisk_eproxy_admin_handler, site},
        {"/api/health", pertisk_eproxy_admin_handler, health},
        {"/api/metrics", pertisk_eproxy_admin_handler, metrics},
        {"/api/reload", pertisk_eproxy_admin_handler, reload},
        {"/api/ingress/live", pertisk_eproxy_admin_handler, ingress_live},
        {"/api/ingress/ready", pertisk_eproxy_admin_handler, ingress_ready},
        {"/api/ingress/status", pertisk_eproxy_admin_handler, ingress_status},
        {"/api/ingress/watchers", pertisk_eproxy_admin_handler, ingress_watchers},
        {"/api/ingress/errors", pertisk_eproxy_admin_handler, ingress_errors},
        {"/api/ingress/resources", pertisk_eproxy_admin_handler, ingress_resources},
        {"/api/kubernetes/namespaces", pertisk_eproxy_admin_handler, kubernetes_namespaces},
        {"/api/kubernetes/pods", pertisk_eproxy_admin_handler, kubernetes_pods},
        {"/api/kubernetes/services", pertisk_eproxy_admin_handler, kubernetes_services},
        {"/api/kubernetes/tls-secrets", pertisk_eproxy_admin_handler, kubernetes_tls_secrets},
        {"/api/kubernetes/ingresses", pertisk_eproxy_admin_handler, kubernetes_ingresses},
        {"/api/kubernetes/ingresses/:namespace/:name", pertisk_eproxy_admin_handler, kubernetes_ingress}
    ].

-spec dispatch() -> cowboy_router:dispatch_rule().
dispatch() ->
    cowboy_router:compile([{'_', api_routes()}]).

%% SPA + static assets (management listener and HTTP/3 local dispatch).
-spec management_ui_routes() -> [cowboy_router:route_path()].
management_ui_routes() ->
    AdminDir = filename:join([code:priv_dir(pertisk_eproxy), "admin"]),
    [
        {"/assets/[...]", cowboy_static, {dir, filename:join([AdminDir, "assets"])}},
        {"/favicon.svg", cowboy_static, {file, filename:join([AdminDir, "favicon.svg"])}},
        {"/", pertisk_eproxy_spa_handler, []},
        {"/[...]", pertisk_eproxy_spa_handler, []}
    ].

%% Full management site: REST API + admin UI (used by HTTP/3 in-process dispatch).
-spec management_dispatch() -> cowboy_router:dispatch_rule().
management_dispatch() ->
    pertisk_eproxy_admin_swagger:management_dispatch().
