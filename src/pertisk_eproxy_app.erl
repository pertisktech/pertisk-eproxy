%% @doc Application callback for pertisk_eproxy.
-module(pertisk_eproxy_app).
-behaviour(application).

-export([start/2, stop/1]).
-export([
    quic_noise_filter/2,
    reload_tls_listeners/0,
    reload_proxy_tls_listeners/0
]).

-define(DEFAULT_DOWNSTREAM_IDLE_TIMEOUT_MS, 300000).
-define(DEFAULT_UPSTREAM_REQUEST_TIMEOUT_MS, 180000).
-define(DOWNSTREAM_IDLE_SAFETY_MARGIN_MS, 5000).
-define(ANSI_RESET, "\e[0m").
-define(ANSI_CYAN, "\e[1;36m").
-define(ANSI_GREEN, "\e[1;32m").

start(_StartType, _StartArgs) ->
    Vsn =
        case application:get_key(pertisk_eproxy, vsn) of
            {ok, V} -> V;
            _ -> <<"unknown">>
        end,
    ok = print_startup_banner(Vsn),
    lager:info(
        "Starting pertisk_eproxy ~s (config storage: SQLite, db=~s)",
        [Vsn, pertisk_eproxy_config:db_file()]
    ),
    _ = install_quic_log_filter(),
    _ = application:ensure_all_started(inets),
    ok = bootstrap_first_start_artifacts(),
    ok = pertisk_eproxy_metrics:setup(),
    ok = pertisk_eproxy_admin_management_snapshot:init_cpu_sample(),
    {ok, Sup} = pertisk_eproxy_sup:start_link(),
    ok = maybe_set_ingress_mode(),
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

%% @doc Full listener restart (management + proxy). Prefer {@link reload_proxy_tls_listeners/0} in ingress mode.
reload_tls_listeners() ->
    stop_proxy_tls_listeners(),
    stop_listener(http4),
    stop_listener(http6),
    stop_listener(management),
    start_listeners().

%% @doc Restart only HTTPS/HTTP/3 proxy listeners after ingress TLS reconcile.
reload_proxy_tls_listeners() ->
    Config = pertisk_eproxy_config:get_config(),
    Routes = build_proxy_routes(),
    stop_proxy_tls_listeners(),
    start_proxy_tls_listeners(Config, Routes),
    ok.

%% -------------------------------------------------------------------------
%% Internal
%% -------------------------------------------------------------------------

print_startup_banner(Vsn) ->
    Config = pertisk_eproxy_config:get_config(),
    VsnText = vsn_text(Vsn),
    ModeText = mode_text(),
    PortsText = ports_text(Config),
    io:format("~s~n", [?ANSI_CYAN]),
    io:format("  ____  _____ ____ _____ ___ ____  _  __~n", []),
    io:format(" |  _ \\| ____|  _ \\_   _|_ _/ ___|| |/ /~n", []),
    io:format(" | |_) |  _| | |_) || |  | |\\___ \\| ' / ~n", []),
    io:format(" |  __/| |___|  _ < | |  | | ___) | . \\ ~n", []),
    io:format(" |_|   |_____|_| \\_\\|_| |___|____/|_|\\_\\~n", []),
    io:format("                e p r o x y~n", []),
    io:format("~n", []),
    io:format("~s", [?ANSI_GREEN]),
    io:format("  version: ~s~n", [VsnText]),
    io:format("  mode: ~s~n", [ModeText]),
    io:format("  port: ~s~n", [PortsText]),
    io:format("~s~n", [?ANSI_RESET]),
    ok.

mode_text() ->
    case pertisk_ingress_env:ingress_mode() of
        true -> "ingress";
        false -> "proxy"
    end.

ports_text(Config) ->
    HttpPort = maps:get(http_port, Config, 80),
    HttpsText =
        case maps:get(https_port, Config, undefined) of
            P when is_integer(P), P > 0 -> integer_to_list(P);
            _ -> "disabled"
        end,
    MgmtPort = maps:get(management_port, Config, 9080),
    lists:flatten(
        io_lib:format("http=~w, https=~s, management=~w", [HttpPort, HttpsText, MgmtPort])
    ).

vsn_text(V) when is_binary(V) ->
    binary_to_list(V);
vsn_text(V) when is_list(V) ->
    V;
vsn_text(V) ->
    lists:flatten(io_lib:format("~p", [V])).

start_listeners() ->
    Config = pertisk_eproxy_config:get_config(),
    Routes = build_proxy_routes(),
    HttpAcceptors = listener_acceptors(http),
    MgmtAcceptors = listener_acceptors(management),

    %% HTTP listeners (proxy): dual-stack (IPv4 + IPv6)
    HttpPort   = maps:get(http_port, Config, 80),
    ok = start_clear_listener(http4, HttpPort, {0, 0, 0, 0}, Routes, HttpAcceptors, []),
    ok = start_clear_listener_ipv6(http6, HttpPort, Routes, HttpAcceptors),
    lager:info("HTTP proxy listening on 0.0.0.0:~w (http4)", [HttpPort]),

    start_proxy_tls_listeners(Config, Routes),

    %% Management / Admin listener (default all IPv4 interfaces; set management_addr in proxy.json to restrict)
    MgmtAddr = maps:get(management_addr, Config, {0,0,0,0}),
    MgmtPort = maps:get(management_port, Config, 9080),
    %% Management listener keeps its own long idle timeout so browser admin sessions
    %% (keep-alive HTTP/1.1) survive across the proxy TLS listener reload that happens
    %% after ACME cert issuance.  The 45 s proxy idle timeout must NOT apply here.
    MgmtIdleTimeoutMs = maps:get(management_idle_timeout_ms, Config, 300000),
    MgmtProtoOpts = #{
        env => #{dispatch => pertisk_eproxy_admin_routes:management_dispatch()},
        logger => pertisk_eproxy_cowboy_logger,
        idle_timeout => MgmtIdleTimeoutMs,
        request_timeout => MgmtIdleTimeoutMs,
        %% Management/admin is intentionally plain HTTP/1.1.
        enable_connect_protocol => false
    },
    ok = start_clear_listener_opts(management, MgmtPort, MgmtAddr, MgmtAcceptors, [], MgmtProtoOpts),
    lager:info("Management API listening on ~s:~w (http/1.1)", [inet:ntoa(MgmtAddr), MgmtPort]),
    ok.

start_proxy_tls_listeners(Config, Routes) ->
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
                    case pertisk_ingress_env:enabled() of
                        true ->
                            lager:info(
                                "HTTPS/HTTP/3 on port ~w waiting for Kubernetes Ingress TLS (not using listener.pem)",
                                [HttpsPort]
                            );
                        false ->
                            lager:warning(
                                "HTTPS not started on port ~w: no TLS material configured",
                                [HttpsPort]
                            )
                    end,
                    ok;
                _ ->
                    start_https_proxy_listeners(HttpsPort, TlsOpts, Routes)
            end
    end,
    maybe_start_quic(Config, Routes),
    ok.

stop_proxy_tls_listeners() ->
    _ = pertisk_eproxy_h3_api_gateway:stop(),
    _ = pertisk_eproxy_h3_api_gateway:stop_probe(),
    stop_listener(https4),
    stop_listener(https6),
    stop_listener(quic4),
    stop_listener(quic6),
    ok.

start_https_proxy_listeners(HttpsPort, TlsOpts, Routes) ->
    Config = pertisk_eproxy_config:get_config(),
    HttpsAcceptors = listener_acceptors(proxy),
    ProxyMaxConns = listener_max_connections(https4, Config),
    DownstreamIdleTimeoutMs = downstream_idle_timeout_ms(Config),
    TlsSocketOpts4 = [{ip, {0,0,0,0}}, {port, HttpsPort} | TlsOpts],
    TlsSocketOpts6 = [{ip, {0,0,0,0,0,0,0,0}}, inet6, {ipv6_v6only, true}, {port, HttpsPort} | TlsOpts],
    HttpsProtoOpts = #{
        env => #{dispatch => cowboy_router:compile([{'_', Routes}])},
        logger => pertisk_eproxy_cowboy_logger,
        idle_timeout => DownstreamIdleTimeoutMs,
        %% request_timeout controls how long Cowboy waits for the *next* request
        %% on a keep-alive connection after completing the previous response.
        %% The default is 5 s, which is shorter than Docker buildkit's inter-request
        %% gap (POST → PUT for blob uploads), causing spurious EOF on large pushes.
        request_timeout => DownstreamIdleTimeoutMs,
        %% RFC 8441: allow WebSocket to tunnel inside an HTTP/2 CONNECT stream.
        enable_connect_protocol => true
    },
    case cowboy:start_tls(https4,
        #{num_acceptors => HttpsAcceptors, max_connections => ProxyMaxConns, socket_opts => TlsSocketOpts4},
        HttpsProtoOpts
    ) of
        {ok, _} ->
            case cowboy:start_tls(https6,
                #{num_acceptors => HttpsAcceptors, max_connections => ProxyMaxConns, socket_opts => TlsSocketOpts6},
                HttpsProtoOpts
            ) of
                {ok, _} ->
                    lager:info("HTTPS proxy listening on 0.0.0.0:~w and [::]:~w", [HttpsPort, HttpsPort]);
                {error, Reason6} ->
                    lager:warning(
                        "HTTPS IPv6 listener https6 not started (~p); IPv4 https4 on :~w only",
                        [Reason6, HttpsPort]
                    )
            end,
            ok;
        {error, Reason4} ->
            lager:error("HTTPS IPv4 listener https4 failed on port ~p: ~p", [HttpsPort, Reason4]),
            {error, Reason4}
    end.

maybe_start_quic(Config, Routes) ->
    GatewayEnabled = maps:get(h3_api_gateway_enabled, Config, true),
    ProxyMaxConns = listener_max_connections(quic4, Config),
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
            StartQuic = quic_start_quic_fun(),
            case erlang:function_exported(cowboy, StartQuic, 3) of
                true ->
                    R1 = catch erlang:apply(cowboy, StartQuic, [
                        quic4,
                        #{
                            num_acceptors => listener_acceptors(proxy),
                            max_connections => ProxyMaxConns,
                            socket_opts => QuicSocketOpts4
                        },
                        QuicProtoOpts
                    ]),
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

listener_acceptors(management) ->
    Schedulers = erlang:system_info(schedulers_online),
    max(2, min(16, Schedulers));
listener_acceptors(_) ->
    Schedulers = erlang:system_info(schedulers_online),
    max(4, min(32, Schedulers * 2)).

quic_start_quic_fun() ->
    binary_to_atom(<<"start_quic">>, utf8).

maybe_start_h3_api_gateway(Config) ->
    case maps:get(h3_api_gateway_enabled, Config, true) of
        true ->
            case pertisk_eproxy_h3_api_gateway:start(Config) of
                {ok, _Pid} ->
                    lager:info("HTTP/3 API gateway (erlang_quic) listening on udp/:~w", [maps:get(quic_port, Config, maps:get(https_port, Config, 443))]),
                    ok;
                {error, {already_started, _}} ->
                    ok;
                {error, {missing_tls_file, Type, Path}} ->
                    lager:info(
                        "HTTP/3 API gateway disabled: missing TLS ~p file (~p)",
                        [Type, Path]
                    ),
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
                {error, {missing_tls_file, Type, Path}} ->
                    lager:info(
                        "HTTP/3 probe listener disabled: missing TLS ~p file (~p)",
                        [Type, Path]
                    ),
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
    case pertisk_ingress_env:ingress_mode() of
        true ->
            ok;
        false ->
            DbPath = pertisk_eproxy_config:db_file(),
            case pertisk_eproxy_db:ensure_ready(DbPath) of
                {ok, _} ->
                    ok;
                {error, Reason} ->
                    lager:warning("Database bootstrap failed (~p), startup will continue", [Reason]),
                    ok
            end
    end,
    maybe_generate_fake_listener_tls(),
    ok.

maybe_generate_fake_listener_tls() ->
    Packaged = {pertisk_eproxy_tls_paths:default_cert_file(),
                pertisk_eproxy_tls_paths:default_key_file()},
    case Packaged of
        {Cert, Key} when is_list(Cert), is_list(Key) ->
            case {filelib:is_file(Cert), filelib:is_file(Key)} of
                {true, true} ->
                    ok;
                _ ->
                    {Wcert, Wkey} = {writable_listener_cert_path(), writable_listener_key_path()},
                    generate_fake_listener_tls(Wcert, Wkey)
            end
    end.

writable_listener_cert_path() ->
    filename:join([pertisk_eproxy_config:data_dir(), "tls", "listener.pem"]).

writable_listener_key_path() ->
    filename:join([pertisk_eproxy_config:data_dir(), "tls", "listener.key"]).

generate_fake_listener_tls(CertPath, KeyPath) ->
    case pertisk_eproxy_shell:openssl_executable() of
        {error, openssl_not_found} ->
            lager:warning(
                "TLS bootstrap skipped: openssl not found and listener PEM missing (~s, ~s)",
                [CertPath, KeyPath]
            ),
            ok;
        {ok, Openssl} ->
            ok = ensure_parent_dir(CertPath),
            ok = ensure_parent_dir(KeyPath),
            Cmd = lists:flatten([
                Openssl,
                " req -x509 -newkey rsa:2048 -sha256 -nodes -days 3650 ",
                "-subj '/CN=localhost' ",
                "-keyout ", shell_quote(KeyPath), " ",
                "-out ", shell_quote(CertPath),
                " 2>&1"
            ]),
            Output = pertisk_eproxy_shell:os_cmd(Cmd),
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
    case maps:get(tls_cert_file, Config, undefined) of
        undefined ->
            case ingress_default_cert_key_paths(Config) of
                {C, K} when is_list(C), is_list(K) ->
                    {C, K};
                _ ->
                    Cert = pertisk_eproxy_tls_paths:resolve_cert_file(Config),
                    Key = pertisk_eproxy_tls_paths:resolve_key_file(Config),
                    normalize_cert_key_pair(Cert, Key)
            end;
        Cert0 ->
            Key0 = maps:get(tls_key_file, Config, undefined),
            normalize_cert_key_pair(normalize_tls_path(Cert0), normalize_tls_path(Key0))
    end.

normalize_cert_key_pair(Cert, Key) ->
    case {Cert, Key} of
        {undefined, _} -> {undefined, undefined};
        {_, undefined} -> {undefined, undefined};
        {C, K} -> {C, K}
    end.

%% First reconciled Ingress host with TLS on disk (default cert for TCP/QUIC + SNI map).
ingress_default_cert_key_paths(Config) ->
    case pertisk_ingress_env:enabled() of
        false ->
            undefined;
        true ->
            Sites = maps:get(sites, Config, []),
            lists:foldl(
                fun(Site, Acc) ->
                    case Acc of
                        {_, _} ->
                            Acc;
                        undefined ->
                            H = site_host_to_list(maps:get(host, Site, <<>>)),
                            case ingress_sni_paths(H) of
                                {ok, Paths} ->
                                    Paths;
                                error ->
                                    undefined
                            end
                    end
                end,
                undefined,
                Sites
            )
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
    sort_sni_hosts(
        lists:reverse(
        lists:foldl(
                fun(Site, Acc) ->
                H = normalize_site_host(site_host_to_list(maps:get(host, Site, <<>>))),
                case ingress_sni_paths(H) of
                    {ok, {CertPath, KeyPath}} ->
                        case lists:keymember(H, 1, Acc) of
                            true -> Acc;
                            false -> [{H, [{certfile, CertPath}, {keyfile, KeyPath}]} | Acc]
                        end;
                    error ->
                        case {H, resolve_site_cert_paths(Site, CertRowsById)} of
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
                end
            end,
            [],
            Sites
        )
        )
    ).

sort_sni_hosts(Hosts) ->
    lists:sort(fun sni_host_entry_less/2, Hosts).

sni_host_entry_less({H1, _}, {H2, _}) ->
    R1 = sni_host_rank(H1),
    R2 = sni_host_rank(H2),
    case R1 =:= R2 of
        true -> H1 =< H2;
        false -> R1 < R2
    end.

%% Prefer exact host matches before wildcards. For wildcards, longer suffix wins.
sni_host_rank(H) ->
    case lists:prefix("*.", H) of
        true -> {1, -length(H)};
        false -> {0, -length(H)}
    end.

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
                #{name := Name0} = Row ->
                    case cert_ref_to_binary(Name0) of
                        <<"acme/", _/binary>> = Name1 -> acme_paths_for_name(Name1);
                        _ -> cert_paths_from_row(IdRef, Row)
                    end;
                _ ->
                    undefined
            end
    end.

cert_paths_from_row(RefBin, #{cert_pem := CertPem0, key_pem := KeyPem0}) ->
    CertPem = pem_text_bin(CertPem0),
    KeyPem = pem_text_bin(KeyPem0),
    case {CertPem, KeyPem} of
        {undefined, _} ->
            undefined;
        {_, undefined} ->
            undefined;
        {CertPemBin, KeyPemBin} ->
            write_site_cert_files(RefBin, CertPemBin, KeyPemBin)
    end;
cert_paths_from_row(_RefBin, _Row) ->
    undefined.

write_site_cert_files(RefBin, CertPem, KeyPem) ->
    try
        Slug = site_cert_slug(RefBin),
        Dir = filename:join([pertisk_eproxy_config:data_dir(), "tls", "site_certs", Slug]),
        CertPath = filename:join(Dir, "fullchain.pem"),
        KeyPath = filename:join(Dir, "privkey.pem"),
        ok = filelib:ensure_dir(CertPath),
        ok = file:write_file(CertPath, CertPem),
        ok = file:write_file(KeyPath, KeyPem),
        _ = try file:change_mode(KeyPath, 8#600) catch _:_ -> ok end,
        {CertPath, KeyPath}
    catch
        _:_ ->
            undefined
    end.

site_cert_slug(undefined) ->
    "site";
site_cert_slug(RefBin) when is_binary(RefBin) ->
    Raw = binary_to_list(RefBin),
    re:replace(Raw, "[^A-Za-z0-9._-]", "_", [global, {return, list}]);
site_cert_slug(Ref) when is_list(Ref) ->
    site_cert_slug(unicode:characters_to_binary(Ref, utf8));
site_cert_slug(Ref) ->
    site_cert_slug(unicode:characters_to_binary(io_lib:format("~p", [Ref]), utf8)).

pem_text_bin(undefined) -> undefined;
pem_text_bin(null) -> undefined;
pem_text_bin(V) when is_binary(V) -> V;
pem_text_bin(V) when is_list(V) -> unicode:characters_to_binary(V, utf8);
pem_text_bin(_) -> undefined.

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

normalize_site_host([]) -> [];
normalize_site_host(Host0) when is_list(Host0) ->
    Trim = string:trim(Host0),
    Lower = string:lowercase(Trim),
    NoScheme =
        re:replace(
            Lower,
            "^[a-z][a-z0-9+.-]*://",
            "",
            [{return, list}]
        ),
    NoPath = hd(string:split(NoScheme, "/", all)),
    NoPort = hd(string:split(NoPath, ":", all)),
    NoDot = re:replace(NoPort, "\\.$", "", [{return, list}]),
    case string:trim(NoDot) of
        "" -> [];
        Out -> Out
    end.

ingress_sni_paths(Host) ->
    case pertisk_ingress_env:enabled() of
        true -> pertisk_ingress_tls:paths_for_host(Host);
        false -> error
    end.

maybe_set_ingress_mode() ->
    case pertisk_ingress_env:ingress_mode() of
        true ->
            application:set_env(pertisk_eproxy, mode, ingress),
            pertisk_eproxy_env_auth:configure();
        false ->
            ok
    end.

start_clear_listener(Name, Port, Ip, Routes, NumAcceptors, ExtraSocketOpts) ->
    Config = pertisk_eproxy_config:get_config(),
    DownstreamIdleTimeoutMs = downstream_idle_timeout_ms(Config),
    ProtoOpts = #{
        env => #{dispatch => cowboy_router:compile([{'_', Routes}])},
        logger => pertisk_eproxy_cowboy_logger,
        idle_timeout => DownstreamIdleTimeoutMs,
        request_timeout => DownstreamIdleTimeoutMs
    },
    start_clear_listener_opts(Name, Port, Ip, NumAcceptors, ExtraSocketOpts, ProtoOpts).

start_clear_listener_opts(Name, Port, Ip, NumAcceptors, ExtraSocketOpts, ProtoOpts) ->
    Config = pertisk_eproxy_config:get_config(),
    MaxConns = listener_max_connections(Name, Config),
    SocketOpts = build_listen_socket_opts(Ip, Port, ExtraSocketOpts),
    case cowboy:start_clear(Name,
        #{num_acceptors => NumAcceptors, max_connections => MaxConns, socket_opts => SocketOpts},
        ProtoOpts
    ) of
        {ok, _} ->
            ok;
        {error, eacces} ->
            lager:error(
                "Cannot bind ~p on port ~p (eacces). Ports below 1024 require "
                "CAP_NET_BIND_SERVICE in systemd, or use http_port/https_port >= 1024",
                [Name, Port]
            ),
            {error, eacces};
        {error, Reason} ->
            lager:error("Cannot bind ~p on port ~p: ~p", [Name, Port, Reason]),
            {error, Reason}
    end.

%% IPv6-only HTTP listener; optional when the host has no working IPv6 stack.
start_clear_listener_ipv6(Name, Port, Routes, NumAcceptors) ->
    case start_clear_listener(Name, Port, {0, 0, 0, 0, 0, 0, 0, 0}, Routes, NumAcceptors,
        [inet6, {ipv6_v6only, true}]
    ) of
        ok ->
            lager:info("HTTP proxy listening on [::]:~w (~p)", [Port, Name]),
            ok;
        {error, Reason} ->
            lager:warning("HTTP/IPv6 listener ~p not started (~p); IPv4 only", [Name, Reason]),
            ok
    end.

%% inet6 must be the bare atom `inet6`, not `{inet6, true}` (causes inet6_tcp badarg).
build_listen_socket_opts({0, 0, 0, 0, 0, 0, 0, 0}, Port, Extra) ->
    [{ip, {0, 0, 0, 0, 0, 0, 0, 0}}, inet6, {port, Port} | Extra];
build_listen_socket_opts(Ip, Port, Extra) ->
    [{ip, Ip}, {port, Port} | Extra].

listener_max_connections(Name, Config) when Name =:= management ->
    maps:get(management_max_connections, Config, 2048);
listener_max_connections(_Name, Config) ->
    maps:get(proxy_max_connections, Config, 16384).

downstream_idle_timeout_ms(Config) ->
    Configured =
        case maps:get(downstream_idle_timeout_ms, Config, ?DEFAULT_DOWNSTREAM_IDLE_TIMEOUT_MS) of
            ConfiguredN when is_integer(ConfiguredN), ConfiguredN > 0 -> ConfiguredN;
            _ -> ?DEFAULT_DOWNSTREAM_IDLE_TIMEOUT_MS
        end,
    UpstreamReqTimeout =
        case maps:get(upstream_request_timeout_ms, Config, ?DEFAULT_UPSTREAM_REQUEST_TIMEOUT_MS) of
            RequestTimeoutN when is_integer(RequestTimeoutN), RequestTimeoutN > 0 -> RequestTimeoutN;
            _ -> ?DEFAULT_UPSTREAM_REQUEST_TIMEOUT_MS
        end,
    MinSafe = UpstreamReqTimeout + ?DOWNSTREAM_IDLE_SAFETY_MARGIN_MS,
    case Configured >= MinSafe of
        true ->
            Configured;
        false ->
            lager:warning(
                "downstream_idle_timeout_ms (~p) is below safe minimum (~p) for upstream_request_timeout_ms=~p; clamping",
                [Configured, MinSafe, UpstreamReqTimeout]
            ),
            MinSafe
    end.
