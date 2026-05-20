%% @doc Application callback for pertisk_eproxy.
-module(pertisk_eproxy_app).
-behaviour(application).

-export([start/2, stop/1]).
-export([quic_noise_filter/2, reload_tls_listeners/0]).

start(_StartType, _StartArgs) ->
    lager:info("Starting pertisk_eproxy"),
    _ = install_quic_log_filter(),
    _ = application:ensure_all_started(inets),
    ok = bootstrap_first_start_artifacts(),
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
    HttpPort   = maps:get(http_port, Config, 80),
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

    %% HTTPS listeners (proxy): dual-stack (IPv4 + IPv6), optional TLS.
    %% If `https_port` is omitted but listener PEMs exist (defaults match the H3 gateway), TCP TLS uses 443.
    %% Set https_port to a positive integer to choose a port; use https_port <= 0 in config to disable TCP HTTPS.
    TlsOpts = tls_opts(Config),
    HttpsPortRes = case maps:find(https_port, Config) of
        {ok, P} when is_integer(P), P > 0 ->
            {explicit, P};
        {ok, P} when is_integer(P), P =< 0 ->
            none;
        {ok, _} ->
            none;
        error when TlsOpts =/= [] ->
            {inferred, 443};
        error ->
            none
    end,
    case HttpsPortRes of
        none ->
            ok;
        {Kind, HttpsPort} when Kind =:= explicit; Kind =:= inferred ->
            case TlsOpts of
                [] ->
                    lager:warning(
                        "HTTPS not started on port ~w: no tls_cert_file/tls_key_file and no readable "
                        "priv/tls/listener.pem + priv/tls/listener.key (set paths in config or install PEMs)",
                        [HttpsPort]
                    ),
                    ok;
                _ when Kind =:= inferred ->
                    start_https_proxy_listeners(HttpsPort, TlsOpts, Routes);
                _ ->
                    start_https_proxy_listeners(HttpsPort, TlsOpts, Routes)
            end
    end,

    maybe_start_quic(Config, Routes),

    %% Management / Admin listener (default all IPv4 interfaces; set management_addr in proxy.json to restrict)
    MgmtAddr = maps:get(management_addr, Config, {0,0,0,0}),
    MgmtPort = maps:get(management_port, Config, 9080),
    MgmtProtoOpts = #{
        env => #{dispatch => cowboy_router:compile([{'_', AdminRoutes}])},
        logger => pertisk_eproxy_cowboy_logger,
        %% Management/admin is intentionally plain HTTP/1.1.
        enable_connect_protocol => false
    },
    {ok, _} = cowboy:start_clear(management,
        #{num_acceptors => 10, socket_opts => [{ip, MgmtAddr}, {port, MgmtPort}]},
        MgmtProtoOpts
    ),
    lager:info("Management API listening on ~s:~w (http/1.1)", [inet:ntoa(MgmtAddr), MgmtPort]),
    ok.

start_https_proxy_listeners(HttpsPort, TlsOpts, Routes) ->
    TlsSocketOpts4 = [{ip, {0,0,0,0}}, {port, HttpsPort} | TlsOpts],
    TlsSocketOpts6 = [{ip, {0,0,0,0,0,0,0,0}}, inet6, {ipv6_v6only, true}, {port, HttpsPort} | TlsOpts],
    HttpsProtoOpts = #{
        env => #{dispatch => cowboy_router:compile([{'_', Routes}])},
        logger => pertisk_eproxy_cowboy_logger,
        %% RFC 8441: allow WebSocket to tunnel inside an HTTP/2 CONNECT stream.
        enable_connect_protocol => true
    },
    {ok, _} = cowboy:start_tls(https4,
        #{
            num_acceptors => 100,
            socket_opts => TlsSocketOpts4
        },
        HttpsProtoOpts
    ),
    {ok, _} = cowboy:start_tls(https6,
        #{
            num_acceptors => 100,
            socket_opts => TlsSocketOpts6
        },
        HttpsProtoOpts
    ),
    lager:info("HTTPS proxy listening on 0.0.0.0:~w and [::]:~w", [HttpsPort, HttpsPort]),
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

bootstrap_first_start_artifacts() ->
    DbPath = pertisk_eproxy_config:db_file(),
    case pertisk_eproxy_db:init(DbPath) of
        {ok, _} ->
            ok;
        {error, Reason} ->
            lager:warning("Database bootstrap failed (~p), startup will continue", [Reason]),
            ok
    end,
    maybe_generate_fake_listener_tls(),
    ok.

maybe_generate_fake_listener_tls() ->
    {CertPath, KeyPath} = listener_tls_paths(),
    case {filelib:is_file(CertPath), filelib:is_file(KeyPath)} of
        {true, true} ->
            ok;
        _ ->
            generate_fake_listener_tls(CertPath, KeyPath)
    end.

listener_tls_paths() ->
    Cert = normalize_tls_path(application:get_env(pertisk_eproxy, tls_cert_file, "priv/tls/listener.pem")),
    Key = normalize_tls_path(application:get_env(pertisk_eproxy, tls_key_file, "priv/tls/listener.key")),
    {Cert, Key}.

generate_fake_listener_tls(CertPath, KeyPath) ->
    case os:find_executable("openssl") of
        false ->
            lager:warning(
                "TLS bootstrap skipped: openssl not found and listener PEM missing (~s, ~s)",
                [CertPath, KeyPath]
            ),
            ok;
        Openssl ->
            ok = ensure_parent_dir(CertPath),
            ok = ensure_parent_dir(KeyPath),
            Cmd = iolist_to_binary([
                shell_quote(Openssl),
                " req -x509 -newkey rsa:2048 -sha256 -nodes -days 3650 ",
                "-subj '/CN=localhost' ",
                "-keyout ", shell_quote(KeyPath), " ",
                "-out ", shell_quote(CertPath),
                " 2>&1"
            ]),
            Output = os:cmd(binary_to_list(Cmd)),
            case {filelib:is_file(CertPath), filelib:is_file(KeyPath)} of
                {true, true} ->
                    _ = try file:change_mode(KeyPath, 8#600) catch _:_ -> ok end,
                    lager:warning(
                        "Generated self-signed listener TLS certificate for first startup (~s, ~s)",
                        [CertPath, KeyPath]
                    ),
                    ok;
                _ ->
                    lager:warning(
                        "TLS bootstrap failed to generate listener PEM via openssl: ~s",
                        [string:trim(Output)]
                    ),
                    ok
            end
    end.

ensure_parent_dir(Path) ->
    case filelib:ensure_dir(Path) of
        ok -> ok;
        {error, Reason} ->
            lager:warning("Failed to create parent directory for ~s: ~p", [Path, Reason]),
            ok
    end.

shell_quote(Path) when is_binary(Path) ->
    shell_quote(binary_to_list(Path));
shell_quote(Path) when is_list(Path) ->
    [$' | shell_quote_1(Path)] ++ "'".

shell_quote_1([]) ->
    [];
shell_quote_1([$' | Rest]) ->
    "'\\''" ++ shell_quote_1(Rest);
shell_quote_1([C | Rest]) ->
    [C | shell_quote_1(Rest)].

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
        %% Realtime admin stream via WebSocket.
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
    pertisk_eproxy_admin_routes:api_routes().

tls_opts(Config) ->
    case tls_cert_key_paths(Config) of
        {undefined, undefined} ->
            [];
        {CertFile, KeyFile} ->
            H2Enabled = maps:get(tls_http2_enabled, Config, true),
            Alpn = case H2Enabled of
                false -> [<<"http/1.1">>];
                _ -> [<<"h2">>, <<"http/1.1">>]
            end,
            Base = [{certfile, CertFile}, {keyfile, KeyFile},
             {versions, ['tlsv1.2', 'tlsv1.3']},
             {alpn_preferred_protocols, Alpn}],
            SniHosts = build_sni_hosts(Config),
            case SniHosts of
                [] -> Base;
                _ -> Base ++ [{sni_hosts, SniHosts}]
            end
    end.

%% @doc Listener cert paths: explicit `tls_cert_file` / `tls_key_file`, else default PEMs
%% (same files as {@link pertisk_eproxy_h3_api_gateway}) when both exist on disk.
-spec tls_cert_key_paths(map()) -> {undefined | string(), undefined | string()}.
tls_cert_key_paths(Config) ->
    Cert0 = maps:get(tls_cert_file, Config, undefined),
    Key0 = maps:get(tls_key_file, Config, undefined),
    Cert = normalize_tls_path(Cert0),
    Key = normalize_tls_path(Key0),
    case {Cert, Key} of
        {undefined, undefined} ->
            DefC = "priv/tls/listener.pem",
            DefK = "priv/tls/listener.key",
            case {filelib:is_file(DefC), filelib:is_file(DefK)} of
                {true, true} -> {DefC, DefK};
                _ -> {undefined, undefined}
            end;
        {undefined, _} ->
            {undefined, undefined};
        {_, undefined} ->
            {undefined, undefined};
        {C, K} ->
            {C, K}
    end.

normalize_tls_path(undefined) -> undefined;
normalize_tls_path(null) -> undefined;
normalize_tls_path(V) when is_binary(V) -> binary_to_list(V);
normalize_tls_path(V) when is_list(V) -> V;
normalize_tls_path(_) -> undefined.

build_sni_hosts(Config) ->
    Sites = maps:get(sites, Config, []),
    DbPath = pertisk_eproxy_config:db_file(),
    CertRowsById = cert_rows_by_id(DbPath),
    lists:reverse(
        lists:foldl(
            fun(Site, Acc) ->
                Host = site_host_to_list(maps:get(host, Site, <<>>)),
                case {Host, resolve_site_cert_paths(Site, CertRowsById)} of
                    {[], _} ->
                        Acc;
                    {_, undefined} ->
                        Acc;
                    {H, {CertPath, KeyPath}} ->
                        case lists:keymember(H, 1, Acc) of
                            true -> Acc;
                            false -> [{H, [{certfile, CertPath}, {keyfile, KeyPath}]} | Acc]
                        end
                end
            end,
            [],
            Sites
        )
    ).

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
                #{name := Name0} ->
                    case cert_ref_to_binary(Name0) of
                        <<"acme/", _/binary>> = Name1 -> acme_paths_for_name(Name1);
                        _ -> undefined
                    end;
                _ ->
                    undefined
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

site_host_to_list(H) when is_list(H) -> H;
site_host_to_list(H) when is_binary(H) -> binary_to_list(H);
site_host_to_list(_) -> [].
