%% @doc Application callback for pertisk_eproxy.
-module(pertisk_eproxy_app).
-behaviour(application).

-export([start/2, stop/1]).
-export([quic_noise_filter/2, reload_tls_listeners/0, quic_sni_cert_selector/1]).

start(_StartType, _StartArgs) ->
    lager:info("Starting pertisk_eproxy"),
    _ = install_quic_log_filter(),
    _ = application:ensure_all_started(inets),
    ok = pertisk_eproxy_metrics:setup(),
    ok = pertisk_eproxy_admin_management_snapshot:init_cpu_sample(),
    {ok, Sup} = pertisk_eproxy_sup:start_link(),
    ok = start_listeners(),
    ok = pertisk_eproxy_auth0:maybe_prefetch_jwks(),
    {ok, Sup}.

stop(_State) ->
    _ = pertisk_eproxy_h3_api_gateway:stop(),
    _ = pertisk_eproxy_h3_api_gateway:stop_probe(),
    stop_listener(http4),
    stop_listener(http6),
    stop_listener(https4),
    stop_listener(https6),
    stop_listener(quic4),
    stop_listener(quic6),
    stop_listener(management),
    ok.

%% @doc Reload listeners so updated TLS cert/key paths are applied immediately.
reload_tls_listeners() ->
    _ = pertisk_eproxy_h3_api_gateway:stop(),
    _ = pertisk_eproxy_h3_api_gateway:stop_probe(),
    stop_listener(http4),
    stop_listener(http6),
    stop_listener(https4),
    stop_listener(https6),
    stop_listener(quic4),
    stop_listener(quic6),
    stop_listener(management),
    start_listeners().

%% -------------------------------------------------------------------------
%% Internal
%% -------------------------------------------------------------------------

start_listeners() ->
    Config = pertisk_eproxy_config:get_config(),
    Routes = build_proxy_routes(),
    AdminRoutes = build_admin_routes(maps:get(mode, Config, proxy_admin)),

    %% HTTP listeners (proxy): dual-stack (IPv4 + IPv6)
    HttpPort   = maps:get(http_port, Config, 8080),
    {ok, _}    = cowboy:start_clear(http4,
        #{
            num_acceptors => 100,
            socket_opts => [{ip, {0,0,0,0}}, {port, HttpPort}]
        },
        #{
            env => #{dispatch => cowboy_router:compile([{'_', Routes}])},
            logger => pertisk_eproxy_cowboy_logger
        }
    ),
    {ok, _}    = cowboy:start_clear(http6,
        #{
            num_acceptors => 100,
            socket_opts => [{ip, {0,0,0,0,0,0,0,0}}, inet6, {ipv6_v6only, true}, {port, HttpPort}]
        },
        #{
            env => #{dispatch => cowboy_router:compile([{'_', Routes}])},
            logger => pertisk_eproxy_cowboy_logger
        }
    ),
    lager:info("HTTP proxy listening on 0.0.0.0:~w and [::]:~w", [HttpPort, HttpPort]),

    %% HTTPS listeners (proxy): dual-stack (IPv4 + IPv6), optional TLS
    case resolve_https_listen(Config) of
        {ok, HttpsPort} ->
            TlsOpts = tls_opts(Config),
            case TlsOpts of
                [] ->
                    lager:warning(
                        "HTTPS TCP not started on port ~w: tls_cert_file / tls_key_file missing or invalid. "
                        "Browsers need TCP TLS for https:// (HTTP/2); QUIC alone is not enough.",
                        [HttpsPort]
                    );
                _ ->
                    TlsSocketOpts4 = [{ip, {0,0,0,0}}, {port, HttpsPort} | TlsOpts],
                    TlsSocketOpts6 = [{ip, {0,0,0,0,0,0,0,0}}, inet6, {ipv6_v6only, true}, {port, HttpsPort} | TlsOpts],
                    {ok, _} = cowboy:start_tls(https4,
                        #{
                            num_acceptors => 100,
                            socket_opts => TlsSocketOpts4
                        },
                        #{
                            env => #{dispatch => cowboy_router:compile([{'_', Routes}])},
                            logger => pertisk_eproxy_cowboy_logger
                        }
                    ),
                    {ok, _} = cowboy:start_tls(https6,
                        #{
                            num_acceptors => 100,
                            socket_opts => TlsSocketOpts6
                        },
                        #{
                            env => #{dispatch => cowboy_router:compile([{'_', Routes}])},
                            logger => pertisk_eproxy_cowboy_logger
                        }
                    ),
                    lager:info("HTTPS proxy listening on 0.0.0.0:~w and [::]:~w", [HttpsPort, HttpsPort])
            end;
        error ->
            ok
    end,

    maybe_start_quic(Config, Routes),

    %% Management / Admin listener (local only by default)
    MgmtAddr = maps:get(management_addr, Config, {127,0,0,1}),
    MgmtPort = maps:get(management_port, Config, 9080),
    {ok, _}  = cowboy:start_clear(management,
        #{
            num_acceptors => 10,
            socket_opts => [{ip, MgmtAddr}, {port, MgmtPort}]
        },
        #{
            env => #{dispatch => cowboy_router:compile([{'_', AdminRoutes}])},
            logger => pertisk_eproxy_cowboy_logger
        }
    ),
    lager:info("Management API listening on ~s:~w", [inet:ntoa(MgmtAddr), MgmtPort]),
    ok.

maybe_start_quic(Config, Routes) ->
    GatewayEnabled = maps:get(h3_api_gateway_enabled, Config, true),
    _ = maybe_start_h3_api_gateway(Config),
    _ = maybe_start_h3_probe(Config),
    case {maps:get(quic_enabled, Config, false), GatewayEnabled} of
        {_, true} ->
            %% When erlang_quic gateway is enabled we reserve UDP QUIC port for it.
            ok;
        {true, false} ->
            Port = case maps:get(quic_port, Config, undefined) of
                P when is_integer(P), P > 0 -> P;
                _ -> maps:get(https_port, Config, 443)
            end,
            Tls = tls_opts(Config),
            QuicSocketOpts4 = [{ip, {0,0,0,0}}, {port, Port} | Tls],
            QuicProtoOpts = #{
                env => #{dispatch => cowboy_router:compile([{'_', Routes}])},
                logger => pertisk_eproxy_cowboy_logger,
                enable_connect_protocol => true,
                h3_datagram => true,
                wt_max_sessions => 16,
                enable_webtransport => true
            },
            case erlang:function_exported(cowboy, start_quic, 3) of
                true ->
                    R1 = catch cowboy:start_quic(quic4,
                        #{
                            num_acceptors => 100,
                            socket_opts => QuicSocketOpts4
                        }, QuicProtoOpts),
                    case R1 of
                        {ok, _} ->
                            lager:info("QUIC proxy listening on udp/:~w", [Port]),
                            ok;
                        _ ->
                            lager:warning("QUIC start requested but failed (~p). Keep using HTTP/1.1+HTTP/2 on TCP 443.", [R1]),
                            ok
                    end;
                false ->
                    lager:warning("QUIC requested on udp/:~w but Cowboy was built without start_quic/3 (enable COWBOY_QUICER=1 and quicer dependency).", [Port]),
                    ok
            end;
        _ ->
            ok
    end.

maybe_start_h3_api_gateway(Config) ->
    case maps:get(h3_api_gateway_enabled, Config, true) of
        true ->
            case pertisk_eproxy_h3_api_gateway:start(Config) of
                {ok, _Pid} ->
                    lager:info("HTTP/3 API gateway (erlang_quic) listening on udp/:~w", [maps:get(quic_port, Config, maps:get(https_port, Config, 443))]),
                    ok;
                {error, {already_started, _}} ->
                    ok;
                {error, Reason} ->
                    lager:warning("HTTP/3 API gateway failed to start: ~p", [Reason]),
                    ok
            end;
        _ ->
            ok
    end.

maybe_start_h3_probe(Config) ->
    case maps:get(h3_probe_enabled, Config, true) of
        true ->
            case pertisk_eproxy_h3_api_gateway:start_probe(Config) of
                {ok, _Pid} ->
                    BasePort = maps:get(quic_port, Config, maps:get(https_port, Config, 443)),
                    ProbePort = maps:get(h3_probe_port, Config, BasePort + 1),
                    lager:info("HTTP/3 probe listener (erlang_quic) listening on udp/:~w", [ProbePort]),
                    ok;
                {error, {already_started, _}} ->
                    ok;
                {error, Reason} ->
                    lager:warning("HTTP/3 probe listener failed to start: ~p", [Reason]),
                    ok
            end;
        _ ->
            ok
    end.

stop_listener(Name) ->
    _ = catch cowboy:stop_listener(Name),
    ok.

install_quic_log_filter() ->
    Filter = {fun ?MODULE:quic_noise_filter/2, #{}},
    case logger:add_primary_filter(quic_unknown_shutdown_filter, Filter) of
        ok -> ok;
        {error, {already_exist, _}} -> ok;
        _ -> ok
    end.

quic_noise_filter(#{msg := Msg}, _Config) ->
    case message_contains_quic_shutdown_noise(Msg) of
        true -> stop;
        false -> ignore
    end;
quic_noise_filter(_, _Config) ->
    ignore.

message_contains_quic_shutdown_noise({string, Format, Args}) ->
    case {Format, Args} of
        {"Received unknown QUIC message ~p.", [{quic, shutdown, _Ref, _Code}]} ->
            true;
        _ ->
            Text = lists:flatten(io_lib:format(Format, Args)),
            string:str(Text, "Received unknown QUIC message {quic,shutdown") > 0
    end;
message_contains_quic_shutdown_noise({report, Report}) ->
    Text = lists:flatten(io_lib:format("~p", [Report])),
    string:str(Text, "Received unknown QUIC message {quic,shutdown") > 0;
message_contains_quic_shutdown_noise(Other) ->
    Text = lists:flatten(io_lib:format("~p", [Other])),
    string:str(Text, "Received unknown QUIC message {quic,shutdown") > 0.

build_proxy_routes() ->
    [
        %% Realtime admin stream must always enter websocket proxy handler directly.
        %% This avoids relying solely on Upgrade header detection in generic handler.
        {"/api/realtime", pertisk_eproxy_ws_handler, []},
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
        {"/api/realtime",           pertisk_eproxy_admin_ws_handler, realtime},
        {"/api/realtime-sse",       pertisk_eproxy_admin_sse_handler, realtime_sse},
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
        {"/api/certificates/import", pertisk_eproxy_admin_handler, certificates_import},
        {"/api/certificates/:id/import", pertisk_eproxy_admin_handler, certificate_import},
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

%% @doc TCP TLS port: use persisted {@code https_port} when present; if omitted but listener PEM paths exist,
%% default to 443 so {@code https://} + HTTP/2 match HTTP/3 QUIC on the same port number.
-spec resolve_https_listen(map()) -> {ok, pos_integer()} | error.
resolve_https_listen(Config) ->
    case maps:find(https_port, Config) of
        {ok, P} when is_integer(P), P > 0 ->
            {ok, P};
        _ ->
            case tls_opts(Config) of
                [] ->
                    error;
                _ ->
                    {ok, maps:get(https_port, Config, 443)}
            end
    end.

tls_opts(Config) ->
    CertFile = maps:get(tls_cert_file, Config, undefined),
    KeyFile  = maps:get(tls_key_file,  Config, undefined),
    case {CertFile, KeyFile} of
        {undefined, _} -> [];
        {_, undefined} -> [];
        _ ->
            Base = [{certfile, CertFile}, {keyfile, KeyFile},
             {versions, ['tlsv1.2', 'tlsv1.3']},
             {alpn_preferred_protocols, [<<"h2">>, <<"http/1.1">>]}],
            %% sni_fun matches client SNI hostnames (including subdomains for wildcard sites).
            %% Mutually exclusive with sni_hosts — required so "*.domain" sites work (static sni_hosts keys are literal).
            DbPath = pertisk_eproxy_config:db_file(),
            SniFun = fun(ServerName) ->
                %% Fresh sites + cert rows on every handshake so hot `put_config` matches TCP TLS.
                Sites = pertisk_eproxy_config:get_sites(),
                CertRowsById = cert_rows_by_id(DbPath),
                case ServerName of
                    [] ->
                        undefined;
                    Name ->
                        HostBin = server_name_to_host_bin(Name),
                        case pertisk_eproxy_router:match_site_for_sni(Sites, HostBin) of
                            error ->
                                undefined;
                            {ok, Site} ->
                                case resolve_site_cert_paths(Site, CertRowsById) of
                                    undefined ->
                                        undefined;
                                    {CertPath, KeyPath} ->
                                        [{certfile, CertPath}, {keyfile, KeyPath}]
                                end
                        end
                end
            end,
            Base ++ [{sni_fun, SniFun}]
    end.

server_name_to_host_bin(Name) when is_list(Name) ->
    try
        string:lowercase(unicode:characters_to_binary(Name, utf8))
    catch _:_ ->
        string:lowercase(list_to_binary(Name))
    end;
server_name_to_host_bin(Name) when is_binary(Name) ->
    string:lowercase(Name);
server_name_to_host_bin(_) ->
    <<>>.

%% @doc QUIC listener hook: return `{LeafDer, IntermediateDers, PrivateKey}' for ClientHello SNI, or `undefined' for default cert.
-spec quic_sni_cert_selector(map()) ->
    fun((binary() | undefined) -> {binary(), [binary()], term()} | undefined).
quic_sni_cert_selector(_Config) ->
    %% Do not capture sites/cert rows from startup: HTTP/3 must follow hot `put_config` like TCP TLS.
    fun(Sni) ->
        DbPath = pertisk_eproxy_config:db_file(),
        Sites = pertisk_eproxy_config:get_sites(),
        CertRowsById = cert_rows_by_id(DbPath),
        HostBin = quic_sni_to_host(Sni),
        case HostBin of
            <<>> ->
                undefined;
            _ ->
                case pertisk_eproxy_router:match_site_for_sni(Sites, HostBin) of
                    error ->
                        undefined;
                    {ok, Site} ->
                        case resolve_site_cert_paths(Site, CertRowsById) of
                            undefined ->
                                undefined;
                            {Cp, Kp} ->
                                case pertisk_eproxy_tls_import:pem_paths_to_quic_server_material(Cp, Kp) of
                                    {ok, Triple} ->
                                        Triple;
                                    _ ->
                                        undefined
                                end
                        end
                end
        end
    end.

quic_sni_to_host(undefined) ->
    <<>>;
quic_sni_to_host(B) when is_binary(B) ->
    string:lowercase(B);
quic_sni_to_host(L) when is_list(L) ->
    try
        string:lowercase(unicode:characters_to_binary(L, utf8))
    catch
        _:_ ->
            string:lowercase(list_to_binary(L))
    end;
quic_sni_to_host(_) ->
    <<>>.

cert_rows_by_id(DbPath) ->
    case pertisk_eproxy_db:list_certificates(DbPath) of
        {ok, Rows} ->
            maps:from_list([{integer_to_binary(maps:get(id, Row)), Row} || Row <- Rows]);
        _ ->
            #{}
    end.

resolve_site_cert_paths(Site, CertRowsById) ->
    case cert_ref_to_binary(maps:get(certificate, Site, undefined)) of
        undefined ->
            undefined;
        <<"acme/", _/binary>> = Name ->
            acme_paths_for_name(Name);
        IdRef ->
            case maps:get(IdRef, CertRowsById, undefined) of
                undefined ->
                    undefined;
                Row ->
                    case cert_ref_to_binary(maps:get(name, Row)) of
                        <<"acme/", _/binary>> = Name1 ->
                            acme_paths_for_name(Name1);
                        _ ->
                            case pertisk_eproxy_tls_import:ensure_certificate_row_pem_files(Row) of
                                undefined ->
                                    undefined;
                                {ok, {CertPath, KeyPath}} ->
                                    {CertPath, KeyPath}
                            end
                    end
            end
    end.

acme_paths_for_name(<<"acme/", Slug/binary>>) ->
    AcmeDir = case application:get_env(pertisk_eproxy, acme_data_dir) of
        {ok, D} when is_list(D) -> D;
        _ -> "data/acme"
    end,
    Dir = filename:join([AcmeDir, "certs", binary_to_list(Slug)]),
    CertPath = filename:join(Dir, "fullchain.pem"),
    KeyPath = filename:join(Dir, "privkey.pem"),
    case {filelib:is_file(CertPath), filelib:is_file(KeyPath)} of
        {true, true} -> {CertPath, KeyPath};
        _ -> undefined
    end.

cert_ref_to_binary(undefined) -> undefined;
cert_ref_to_binary(null) -> undefined;
cert_ref_to_binary(V) when is_binary(V) -> V;
cert_ref_to_binary(V) when is_list(V) -> unicode:characters_to_binary(V, utf8);
cert_ref_to_binary(V) when is_integer(V) -> integer_to_binary(V);
cert_ref_to_binary(_) -> undefined.
