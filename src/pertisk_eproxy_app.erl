%% @doc Application callback for pertisk_eproxy.
-module(pertisk_eproxy_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    lager:info("Starting pertisk_eproxy"),
    ok = pertisk_eproxy_metrics:setup(),
    {ok, Sup} = pertisk_eproxy_sup:start_link(),
    ok = start_listeners(),
    {ok, Sup}.

stop(_State) ->
    cowboy:stop_listener(http),
    cowboy:stop_listener(https),
    cowboy:stop_listener(management),
    ok.

%% -------------------------------------------------------------------------
%% Internal
%% -------------------------------------------------------------------------

start_listeners() ->
    Config = pertisk_eproxy_config:get_config(),
    Routes = build_proxy_routes(),
    AdminRoutes = build_admin_routes(maps:get(mode, Config, proxy_admin)),

    %% HTTP listener (proxy)
    HttpAddr   = maps:get(http_addr, Config, {0,0,0,0}),
    HttpPort   = maps:get(http_port, Config, 8080),
    {ok, _}    = cowboy:start_clear(http,
        [{ip, HttpAddr}, {port, HttpPort}, {num_acceptors, 100}],
        #{env => #{dispatch => cowboy_router:compile([{'_', Routes}])}}
    ),
    lager:info("HTTP proxy listening on ~s:~w", [inet:ntoa(HttpAddr), HttpPort]),

    %% HTTPS listener (proxy) — optional, requires TLS config
    case maps:find(https_port, Config) of
        {ok, HttpsPort} ->
            TlsOpts = tls_opts(Config),
            {ok, _} = cowboy:start_tls(https,
                [{ip, HttpAddr}, {port, HttpsPort}, {num_acceptors, 100} | TlsOpts],
                #{env => #{dispatch => cowboy_router:compile([{'_', Routes}])}}
            ),
            lager:info("HTTPS proxy listening on ~s:~w", [inet:ntoa(HttpAddr), HttpsPort]);
        error ->
            ok
    end,

    %% Management / Admin listener (local only by default)
    MgmtAddr = maps:get(management_addr, Config, {127,0,0,1}),
    MgmtPort = maps:get(management_port, Config, 9080),
    {ok, _}  = cowboy:start_clear(management,
        [{ip, MgmtAddr}, {port, MgmtPort}, {num_acceptors, 10}],
        #{env => #{dispatch => cowboy_router:compile([{'_', AdminRoutes}])}}
    ),
    lager:info("Management API listening on ~s:~w", [inet:ntoa(MgmtAddr), MgmtPort]),
    ok.

build_proxy_routes() ->
    [
        {"/[...]", pertisk_eproxy_handler, []}
    ].

build_admin_routes(proxy) ->
    build_admin_api_routes() ++ [
        {"/",                       pertisk_eproxy_admin_handler, root}
    ];
build_admin_routes(proxy_admin) ->
    build_admin_api_routes() ++ [
        %% Static admin UI
        {"/assets/[...]",          cowboy_static, {dir, filename:join([code:priv_dir(pertisk_eproxy), "admin", "assets"])}},
        {"/favicon.svg",           cowboy_static, {file, filename:join([code:priv_dir(pertisk_eproxy), "admin", "favicon.svg"])}},
        {"/",                      pertisk_eproxy_spa_handler, []},
        {"/[...]",                 pertisk_eproxy_spa_handler, []}
    ].

build_admin_api_routes() ->
    [
        %% REST API (management listener on :9080)
        {"/api/version",            pertisk_eproxy_admin_handler, version},
        {"/api/management",         pertisk_eproxy_admin_handler, management},
        {"/api/stats",              pertisk_eproxy_admin_handler, stats},
        {"/api/logs",               pertisk_eproxy_admin_handler, logs},
        {"/api/auth/config",        pertisk_eproxy_admin_handler, auth_config},
        {"/api/auth/login",         pertisk_eproxy_admin_handler, auth_login},
        {"/api/auth/refresh",       pertisk_eproxy_admin_handler, auth_refresh},
        {"/api/auth/check",         pertisk_eproxy_admin_handler, auth_check},
        {"/api/auth/logout",        pertisk_eproxy_admin_handler, auth_logout},
        {"/api/admin/change-password", pertisk_eproxy_admin_handler, admin_change_password},
        {"/api/admin/api-token",    pertisk_eproxy_admin_handler, admin_api_token},
        {"/api/backup/export",      pertisk_eproxy_admin_handler, backup_export},
        {"/api/backup/restore",     pertisk_eproxy_admin_handler, backup_restore},
        {"/api/helm/history",       pertisk_eproxy_admin_handler, helm_history},
        {"/api/helm/values/:revision", pertisk_eproxy_admin_handler, helm_values},
        {"/api/certificates",       pertisk_eproxy_admin_handler, certificates},
        {"/api/certificates/:id",   pertisk_eproxy_admin_handler, certificate},
        {"/api/dns-providers",      pertisk_eproxy_admin_handler, dns_providers},
        {"/api/dns-providers/:id",  pertisk_eproxy_admin_handler, dns_provider},
        {"/api/tls/listener",       pertisk_eproxy_admin_handler, tls_listener},
        {"/api/config",             pertisk_eproxy_admin_handler, config},
        {"/api/backends",           pertisk_eproxy_admin_handler, backends},
        {"/api/backends/:name",     pertisk_eproxy_admin_handler, backend},
        {"/api/sites",              pertisk_eproxy_admin_handler, sites},
        {"/api/sites/:host",        pertisk_eproxy_admin_handler, site},
        {"/api/health",             pertisk_eproxy_admin_handler, health},
        {"/api/metrics",            pertisk_eproxy_admin_handler, metrics},
        {"/api/reload",             pertisk_eproxy_admin_handler, reload}
    ].

tls_opts(Config) ->
    CertFile = maps:get(tls_cert_file, Config, undefined),
    KeyFile  = maps:get(tls_key_file,  Config, undefined),
    case {CertFile, KeyFile} of
        {undefined, _} -> [];
        {_, undefined} -> [];
        _ ->
            [{certfile, CertFile}, {keyfile, KeyFile},
             {versions, ['tlsv1.2', 'tlsv1.3']},
             {alpn_preferred_protocols, [<<"h2">>, <<"http/1.1">>]}]
    end.
