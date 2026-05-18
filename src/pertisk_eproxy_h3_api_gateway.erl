%% @doc HTTP/3 edge listener: same host/path routing and upstream selection as TCP HTTPS.
%%
%% For each request, uses {@link pertisk_eproxy_router:route/2} and
%% {@link pertisk_eproxy_backend:pick_upstream/2}, then forwards with {@link gun}
%% (HTTP or TLS), matching {@link pertisk_eproxy_handler}.
-module(pertisk_eproxy_h3_api_gateway).

-export([start/1, stop/0, start_probe/1, stop_probe/0, handle_request/5]).
-export([management_listener_bind_stack/0]).

-define(SERVER, pertisk_eproxy_h3_api).
-define(PROBE_SERVER, pertisk_eproxy_h3_probe).
-define(SERVER_V4, pertisk_eproxy_h3_api_v4).
-define(PROBE_SERVER_V4, pertisk_eproxy_h3_probe_v4).
%% Max wait per read_request_body (H3 client request DATA). Was a flat 15s and matched ~15003ms access-log timings for small API POSTs (e.g. /api/auth/refresh).
-define(H3_BODY_TIMEOUT_UNKNOWN_CL_MS, 3500).
-define(H3_BODY_TIMEOUT_SMALL_POST_MS, 4000).
-define(H3_BODY_TIMEOUT_LARGE_CAP_MS, 120000).
-define(H3_BODY_AUTH_CAP_MS, 3000).
-define(REQUEST_TIMEOUT, 60000).
-define(CONNECT_TIMEOUT, 10000).

start(Config) ->
    _ = ensure_quic_started(),
    _ = ensure_gun_started(),
    case ensure_qpack_chrome_compat() of
        ok ->
            Port = case maps:get(quic_port, Config, undefined) of
                P when is_integer(P), P > 0 -> P;
                _ -> maps:get(https_port, Config, 443)
            end,
            case load_cert_and_key(Config) of
                {ok, {CertDer, KeyTerm, CertChain}} ->
                    do_start_gateway(Port, CertDer, KeyTerm, CertChain);
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, _} = Err ->
            Err
    end.

do_start_gateway(Port, CertDer, KeyTerm, CertChain) ->
    Config = pertisk_eproxy_config:get_config(),
    CertPath = maps:get(tls_cert_file, Config, "priv/tls/listener.pem"),
    _ = pertisk_eproxy_tls_chain:verify_listener_parity(CertPath, CertDer, CertChain),
    QuicOpts = quic_transport_opts(Config),
    case CertChain of
        [] ->
            lager:warning(
                "HTTP/3 listener: PEM has leaf only (no intermediate certs); "
                "Chrome may reject QUIC while Firefox/curl still work — append chain to listener.pem"
            );
        _ ->
            lager:info("HTTP/3 listener: TLS chain ~p cert(s) (leaf + ~p intermediate(s))",
                       [1 + length(CertChain), length(CertChain)])
    end,
    _ = lager:info(
        "HTTP/3 gateway QUIC opts: idle_timeout=~wms keep_alive_interval=~p max_udp_payload_size=~w max_datagram_frame_size=~w",
        [
            maps:get(idle_timeout, QuicOpts, undefined),
            maps:get(keep_alive_interval, QuicOpts, undefined),
            maps:get(max_udp_payload_size, QuicOpts, undefined),
            maps:get(max_datagram_frame_size, QuicOpts, undefined)
        ]
    ),
    BaseOpts = maps:merge(
        tls_server_opts(CertDer, KeyTerm, CertChain),
        #{
            settings => h3_http_settings(Config),
            handler => ?MODULE,
            quic_opts => QuicOpts
        }
    ),
    start_prefer_ipv6_server(Port, BaseOpts).

stop() ->
    catch quic_h3:stop_server(?SERVER),
    catch quic_h3:stop_server(?SERVER_V4),
    ok.

start_probe(Config) ->
    _ = ensure_quic_started(),
    _ = ensure_gun_started(),
    case ensure_qpack_chrome_compat() of
        ok ->
            BasePort = case maps:get(quic_port, Config, undefined) of
                P when is_integer(P), P > 0 -> P;
                _ -> maps:get(https_port, Config, 443)
            end,
            ProbePort = maps:get(h3_probe_port, Config, BasePort + 1),
            case load_cert_and_key(Config) of
                {ok, {CertDer, KeyTerm, CertChain}} ->
                    do_start_probe(ProbePort, CertDer, KeyTerm, CertChain);
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, _} = Err ->
            Err
    end.

%% Chromium rejects header blocks from older quic_qpack builds where RIC=0
%% was encoded with a pre-base sign bit ("Error calculating Base").
ensure_qpack_chrome_compat() ->
    case qpack_ric0_prefix_ok() of
        true ->
            ok;
        false ->
            lager:error(
                "HTTP/3 disabled: incompatible quic_qpack detected (RIC=0 Base encoding). "
                "Rebuild with vendored _checkouts/quic (for example: make clean && make)."
            ),
            {error, incompatible_quic_qpack}
    end.

qpack_ric0_prefix_ok() ->
    try
        %% Encode a static-only block; RFC 9204 requires RIC=0 and Base=0.
        Encoded = quic_qpack:encode([{<<":status">>, <<"200">>}]),
        case Encoded of
            <<0, 0, _/binary>> -> true;
            _ -> false
        end
    catch
        _:_ -> false
    end.

do_start_probe(ProbePort, CertDer, KeyTerm, CertChain) ->
    Config = pertisk_eproxy_config:get_config(),
    QuicOpts = quic_transport_opts(Config),
    _ = lager:info(
        "HTTP/3 probe QUIC opts: idle_timeout=~wms keep_alive_interval=~p max_udp_payload_size=~w max_datagram_frame_size=~w",
        [
            maps:get(idle_timeout, QuicOpts, undefined),
            maps:get(keep_alive_interval, QuicOpts, undefined),
            maps:get(max_udp_payload_size, QuicOpts, undefined),
            maps:get(max_datagram_frame_size, QuicOpts, undefined)
        ]
    ),
    ProbeOpts = maps:merge(
        tls_server_opts(CertDer, KeyTerm, CertChain),
        #{
            handler => pertisk_eproxy_h3_probe_handler,
            quic_opts => QuicOpts
        }
    ),
    start_prefer_ipv6_server(?PROBE_SERVER, ProbePort, ProbeOpts).

stop_probe() ->
    catch quic_h3:stop_server(?PROBE_SERVER),
    catch quic_h3:stop_server(?PROBE_SERVER_V4),
    ok.

handle_request(H3Conn, StreamId, Method, Path, Headers) ->
    T0 = erlang:monotonic_time(millisecond),
    Auth = authority_host(Headers),
    LogHost = host_for_route(Auth),
    {PathOnly, Qs} = split_path_query(Path),
    try
        Body = read_request_body(H3Conn, StreamId, Method, Headers, PathOnly),
        case pertisk_eproxy_router:route(LogHost, PathOnly) of
            {error, no_route} ->
                pertisk_eproxy_metrics:inc_request(LogHost, <<"404">>, <<"h3">>),
                ok = quic_h3:send_response(
                    H3Conn, StreamId, 404, [{<<"content-type">>, <<"text/plain">>}]
                ),
                _ = quic_h3:send_data(
                    H3Conn,
                    StreamId,
                    <<"No route found for host: ", LogHost/binary>>,
                    true
                ),
                log_h3_access(LogHost, Method, PathOnly, 404, T0, <<>>),
                ok;
            {ok, #{upstream_path := UpPath, backend := BackendName}} ->
                ClientIp = client_ip_h3(H3Conn, Headers),
                case pertisk_eproxy_backend:pick_upstream(BackendName, ClientIp) of
                    {error, no_healthy_upstream} ->
                        pertisk_eproxy_metrics:inc_request(LogHost, <<"502">>, <<"h3">>),
                        reply_502_plain(H3Conn, StreamId),
                        log_h3_access(LogHost, Method, PathOnly, 502, T0, <<>>),
                        ok;
                    {ok, UpstreamAddr} ->
                        ProxyResult =
                            proxy_h3_upstream(
                                Method,
                                LogHost,
                                PathOnly,
                                UpPath,
                                Qs,
                                UpstreamAddr,
                                Headers,
                                Body,
                                ClientIp
                            ),
                        case ProxyResult of
                            {ok, Status0, RespHeaders, RespBody} ->
                                Status = gun_response_status_int(Status0),
                                StatusBin = integer_to_binary(Status),
                                pertisk_eproxy_metrics:inc_request(LogHost, StatusBin, <<"h3">>),
                                RespBin = safe_iolist_to_binary(RespBody),
                                ok = pertisk_eproxy_metrics:record_proxy_bytes(
                                    LogHost, byte_size(Body), byte_size(RespBin)
                                ),
                                ok = pertisk_eproxy_backend:done_upstream(
                                    BackendName, UpstreamAddr, ok
                                ),
                                H3Headers = maybe_add_h3_alt_svc(LogHost, RespHeaders),
                                ok = quic_h3:send_response(H3Conn, StreamId, Status, H3Headers),
                                _ = quic_h3:send_data(H3Conn, StreamId, RespBin, true),
                                UpstreamLog =
                                    case is_management_upstream(UpstreamAddr) of
                                        true -> <<"management-local">>;
                                        false -> UpstreamAddr
                                    end,
                                log_h3_access(LogHost, Method, PathOnly, Status, T0, UpstreamLog),
                                ok;
                            {error, ProxyReason} ->
                                pertisk_eproxy_metrics:inc_request(LogHost, <<"502">>, <<"h3">>),
                                ok = pertisk_eproxy_backend:done_upstream(
                                    BackendName, UpstreamAddr, error
                                ),
                                lager:warning(
                                    "h3 proxy_via_gun failed: ~p host=~s path=~s upstream=~s",
                                    [ProxyReason, LogHost, PathOnly, UpstreamAddr]
                                ),
                                reply_502_plain(H3Conn, StreamId),
                                log_h3_access(LogHost, Method, PathOnly, 502, T0, UpstreamAddr),
                                ok
                        end
                end
        end
    catch
        Class:Reason:Stack ->
            lager:error(
                "h3 handle_request crash class=~p reason=~p host=~s path=~s stack=~p",
                [Class, Reason, LogHost, Path, Stack]
            ),
            _ = catch quic_h3:send_response(
                H3Conn, StreamId, 500, [{<<"content-type">>, <<"text/plain">>}]
            ),
            _ = catch quic_h3:send_data(H3Conn, StreamId, <<"Internal Server Error">>, true),
            log_h3_access(LogHost, Method, PathOnly, 500, T0, <<>>),
            ok
    end.

reply_502_plain(H3Conn, StreamId) ->
    ok = quic_h3:send_response(
        H3Conn, StreamId, 502, [{<<"content-type">>, <<"text/plain">>}]
    ),
    _ = quic_h3:send_data(H3Conn, StreamId, <<"Bad Gateway">>, true),
    ok.

%% Strip a trailing :port for router matching (and log host), same idea as Cowboy's host/1.
host_for_route(<<>>) ->
    <<>>;
host_for_route(AuthBin) when is_binary(AuthBin) ->
    Auth = string:lowercase(AuthBin),
    case re:run(Auth, "^(.+):([0-9]+)\$", [{capture, all_but_first, binary}]) of
        {match, [H, _Port]} -> H;
        nomatch -> Auth
    end.

split_path_query(Path) ->
    case binary:split(Path, <<"?">>) of
        [P, Q] -> {P, Q};
        [P] -> {P, <<>>}
    end.

authority_host(Headers) ->
    case lists:keyfind(<<":authority">>, 1, Headers) of
        {_, V} when is_binary(V) -> V;
        _ -> <<"-">>
    end.

client_ip_h3(H3Conn, Headers) ->
    case lists:keyfind(<<"x-forwarded-for">>, 1, Headers) of
        {_, Xff} when is_binary(Xff) ->
            hd(binary:split(Xff, [<<", ">>, <<",">>]));
        _ ->
            try
                QuicConn = quic_h3:get_quic_conn(H3Conn),
                case quic:peername(QuicConn) of
                    {ok, {PeerIp, _Port}} -> list_to_binary(inet:ntoa(PeerIp));
                    _ -> <<"127.0.0.1">>
                end
            catch
                _:_ -> <<"127.0.0.1">>
            end
    end.

h3_req_headers_map(Headers) ->
    maps:from_list([
        begin
            Kb = string:lowercase(K),
            {Kb, V}
        end
        || {K, V} <- Headers,
           is_binary(K),
           is_binary(V),
           byte_size(K) > 0,
           binary:at(K, 0) =/= $:
    ]).

forward_headers_h3(InMap, OrigHost, ClientIp) when is_binary(OrigHost) ->
    Filtered = maps:without(
        [
            <<"connection">>,
            <<"keep-alive">>,
            <<"te">>,
            <<"trailers">>,
            <<"transfer-encoding">>,
            <<"upgrade">>
        ],
        InMap
    ),
    Base = Filtered#{
        <<"host">> => OrigHost,
        <<"x-forwarded-proto">> => <<"https">>,
        <<"x-forwarded-proto-version">> => <<"HTTP/3">>
    },
    XFF = case maps:find(<<"x-forwarded-for">>, Base) of
        {ok, Existing} -> <<Existing/binary, ", ", ClientIp/binary>>;
        error -> ClientIp
    end,
    Base#{<<"x-forwarded-for">> => XFF}.

%% Match pertisk-rproxy defaults: 300s QUIC idle, 30s keepalive (ms in erlang_quic).
-define(H3_IDLE_TIMEOUT_SECS_DEFAULT, 300).
-define(H3_KEEPALIVE_SECS_DEFAULT, 30).
-define(H3_SAFE_MAX_UDP_PAYLOAD_SIZE, 1200).

%% HTTP/3 SETTINGS sent to clients (Chrome expects default dynamic QPACK like Node/Go/Rust).
h3_http_settings(Config) ->
    case maps:get(h3_qpack_static, Config, true) of
        true ->
            #{
                qpack_max_table_capacity => 0,
                qpack_blocked_streams => 0
            };
        false ->
            #{}
    end.

proxy_h3_upstream(
    Method,
    LogHost,
    PathOnly,
    UpPath,
    Qs,
    UpstreamAddr,
    Headers,
    Body,
    ClientIp
) ->
    case is_management_upstream(UpstreamAddr) of
        true ->
            case pertisk_eproxy_h3_local_admin:try_dispatch(
                Method, LogHost, PathOnly, Qs, Headers, Body, ClientIp
            ) of
                {ok, Status, RespHeaders, RespBody} ->
                    {ok, Status, gun_resp_headers_to_h3(RespHeaders), RespBody};
                {error, unsupported} ->
                    proxy_via_gun(
                        Method, LogHost, UpPath, Qs, UpstreamAddr, Headers, Body, ClientIp
                    );
                {error, Reason} ->
                    {error, {local_admin, Reason}}
            end;
        false ->
            proxy_via_gun(
                Method, LogHost, UpPath, Qs, UpstreamAddr, Headers, Body, ClientIp
            )
    end.

quic_transport_opts(Config) ->
    IdleSecs =
        case maps:get(h3_idle_timeout_secs, Config, undefined) of
            IdleS when is_integer(IdleS), IdleS >= 0 ->
                IdleS;
            _ ->
                ?H3_IDLE_TIMEOUT_SECS_DEFAULT
        end,
    KeepSecs =
        case maps:get(h3_keepalive_interval_secs, Config, undefined) of
            KeepS when is_integer(KeepS), KeepS >= 0 ->
                KeepS;
            _ ->
                ?H3_KEEPALIVE_SECS_DEFAULT
        end,
    Base = #{
        idle_timeout => IdleSecs * 1000,
        %% Chromium can close with QUIC_PACKET_TOO_LARGE on some paths.
        %% Keep server datagrams at QUIC minimum and avoid PMTU probing regressions.
        socket_backend => gen_udp,
        backend => gen_udp,
        batching => #{enabled => false},
        max_datagram_frame_size => 0,
        max_udp_payload_size => ?H3_SAFE_MAX_UDP_PAYLOAD_SIZE,
        pmtu_enabled => false,
        pmtu_max_mtu => ?H3_SAFE_MAX_UDP_PAYLOAD_SIZE
    },
    case KeepSecs of
        0 ->
            Base;
        _ ->
            Base#{keep_alive_interval => max(5000, KeepSecs * 1000)}
    end.

is_management_upstream(UpstreamAddr) ->
    try
        {Host, Port, _} = pertisk_eproxy_handler:parse_upstream(UpstreamAddr),
        C = pertisk_eproxy_config:get_config(),
        Port =:= maps:get(management_port, C, 9080) andalso
            management_host_match(Host, maps:get(management_addr, C, {0, 0, 0, 0}))
    catch
        _:_ ->
            false
    end.

management_host_match(Host, MgmtAddr) when is_binary(Host) ->
    management_host_match(binary_to_list(Host), MgmtAddr);
management_host_match(Host, MgmtAddr) when is_list(Host) ->
    H = string:lowercase(string:trim(Host)),
    Mgmt = string:lowercase(lists:flatten(inet:ntoa(MgmtAddr))),
    lists:member(H, [
        Mgmt,
        "127.0.0.1",
        "localhost",
        "0.0.0.0",
        "::1",
        "[::1]",
        "::",
        "[::]"
    ]).

proxy_via_gun(MethodBin, OrigHost, UpstreamPath, Qs, UpstreamAddr, H3Headers, Body, ClientIp) ->
    {UpHost, UpPort, Transport} = pertisk_eproxy_handler:parse_upstream(UpstreamAddr),
    FullPath = case Qs of
        <<>> -> UpstreamPath;
        _ -> <<UpstreamPath/binary, "?", Qs/binary>>
    end,
    HMap = h3_req_headers_map(H3Headers),
    HeadersMap = forward_headers_h3(HMap, OrigHost, ClientIp),
    HeadersList = maps:to_list(HeadersMap),
    GunMethod = method_to_gun(MethodBin),
    GunOpts = #{
        transport => Transport,
        protocols => [http],
        connect_timeout => ?CONNECT_TIMEOUT
    },
    case gun:open(UpHost, UpPort, GunOpts) of
        {error, Reason} ->
            {error, {connect, Reason}};
        {ok, ConnPid} ->
            case gun:await_up(ConnPid, ?CONNECT_TIMEOUT) of
                {error, Reason} ->
                    gun:close(ConnPid),
                    {error, {await_up, Reason}};
                {ok, _Protocol} ->
                    StreamRef = gun:request(ConnPid, GunMethod, FullPath, HeadersList, Body),
                    Result = case gun:await(ConnPid, StreamRef, ?REQUEST_TIMEOUT) of
                        {response, nofin, Status, RespHeaders} ->
                            case gun:await_body(ConnPid, StreamRef, ?REQUEST_TIMEOUT) of
                                {ok, RespBody} ->
                                    {ok, Status, gun_resp_headers_to_h3(RespHeaders),
                                        safe_iolist_to_binary(RespBody)};
                                {error, R} ->
                                    {error, R}
                            end;
                        {response, fin, Status, RespHeaders} ->
                            {ok, Status, gun_resp_headers_to_h3(RespHeaders), <<>>};
                        {error, R} ->
                            {error, R}
                    end,
                    gun:close(ConnPid),
                    Result
            end
    end.

method_to_gun(<<"GET">>) -> <<"GET">>;
method_to_gun(<<"POST">>) -> <<"POST">>;
method_to_gun(<<"PUT">>) -> <<"PUT">>;
method_to_gun(<<"PATCH">>) -> <<"PATCH">>;
method_to_gun(<<"DELETE">>) -> <<"DELETE">>;
method_to_gun(<<"HEAD">>) -> <<"HEAD">>;
method_to_gun(<<"OPTIONS">>) -> <<"OPTIONS">>;
method_to_gun(M) when is_binary(M) -> string:uppercase(M);
method_to_gun(M) when is_list(M) -> string:uppercase(unicode:characters_to_binary(M));
method_to_gun(M) when is_atom(M) -> method_to_gun(atom_to_binary(M, utf8));
method_to_gun(M) -> unicode:characters_to_binary(io_lib:format("~p", [M])).

gun_response_status_int(S) when is_integer(S), S >= 100, S < 600 ->
    S;
gun_response_status_int(S) when is_binary(S) ->
    try
        case binary_to_integer(S) of
            I when I >= 100, I < 600 -> I;
            _ -> 502
        end
    catch
        _:_ -> 502
    end;
gun_response_status_int(_) ->
    502.

gun_resp_headers_to_h3(Headers) ->
    Blocked = [
        "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
        "te", "trailers", "transfer-encoding", "upgrade",
        "date", "server", "content-length"
    ],
    lists:filtermap(
        fun({K, V}) ->
            try
                Kl = string:lowercase(header_name_str(K)),
                case lists:member(Kl, Blocked) of
                    true ->
                        false;
                    false ->
                        {true, {list_to_binary(Kl), safe_iolist_to_binary(V)}}
                end
            catch
                _:_ ->
                    false
            end
        end,
        Headers
    ).

header_name_str(K) when is_atom(K) -> atom_to_list(K);
header_name_str(K) when is_binary(K) -> unicode:characters_to_list(K, utf8);
header_name_str(K) when is_list(K) -> K;
header_name_str(K) -> unicode:characters_to_list(iolist_to_binary(io_lib:format("~p", [K])), utf8).

safe_iolist_to_binary(V) ->
    try
        iolist_to_binary(V)
    catch
        _:_ ->
            <<>>
    end.

log_h3_access(Host, Method, Path, Status, T0, Upstream) ->
    Dt = max(0, erlang:monotonic_time(millisecond) - T0),
    catch pertisk_eproxy_access_log:log_proxy(Host, Method, Path, Status, Dt, 'HTTP/3', Upstream).

read_request_body(Conn, StreamId, Method0, Headers, PathOnly) ->
    Method = normalize_h3_method(Method0),
    case Method of
        <<"GET">> -> <<>>;
        <<"HEAD">> -> <<>>;
        _ ->
            case h3_skip_request_body(PathOnly) of
                true -> <<>>;
                false -> read_request_body_post(Conn, StreamId, Headers, PathOnly)
            end
    end.

%% Bearer-only auth routes ignore the POST body; waiting for QUIC DATA+FIN (Chrome is slow here)
%% caused ~3s access-log timings and pushed Chrome off HTTP/3 to HTTP/2.
h3_skip_request_body(<<"/api/auth/refresh">>) -> true;
h3_skip_request_body(<<"/api/auth/logout">>) -> true;
h3_skip_request_body(_) -> false.

read_request_body_post(Conn, StreamId, Headers, PathOnly) ->
    Cl = header_content_length_bytes(Headers),
    TimeoutMs = h3_body_collect_timeout_ms(Headers, PathOnly),
    case quic_h3:set_stream_handler(Conn, StreamId, self()) of
        {ok, Buffered} ->
            Acc0 = chunks_to_binary(Buffered),
            collect_body(Conn, StreamId, Acc0, TimeoutMs, Cl);
        ok ->
            collect_body(Conn, StreamId, <<>>, TimeoutMs, Cl);
        _ ->
            <<>>
    end.

normalize_h3_method(M) when is_binary(M) ->
    string:uppercase(M);
normalize_h3_method(M) when is_list(M) ->
    string:uppercase(unicode:characters_to_binary(M));
normalize_h3_method(M) when is_atom(M) ->
    normalize_h3_method(atom_to_binary(M, utf8));
normalize_h3_method(M) ->
    unicode:characters_to_binary(io_lib:format("~p", [M])).

chunks_to_binary(Chunks) ->
    try
        iolist_to_binary([D || {D, _Fin} <- Chunks])
    catch
        _:_ ->
            <<>>
    end.

-spec h3_body_collect_timeout_ms([{binary(), binary()}], binary()) -> pos_integer().
h3_body_collect_timeout_ms(Headers, PathOnly) ->
    T =
        case header_content_length_bytes(Headers) of
            {ok, N} when N =:= 0 ->
                %% Empty body still waits for stream end in some stacks — keep this tight.
                2500;
            {ok, N} when N < 1048576 ->
                ?H3_BODY_TIMEOUT_SMALL_POST_MS;
            {ok, N} ->
                %% Large uploads: scale with declared size (never floor at 15s — that hid QUIC stalls behind a fixed wait).
                min(?H3_BODY_TIMEOUT_LARGE_CAP_MS, max(8000, (N div 4096) + 6000));
            undefined ->
                %% No Content-Length: small JSON / API control frames should finish quickly.
                ?H3_BODY_TIMEOUT_UNKNOWN_CL_MS
        end,
    h3_auth_route_body_cap(PathOnly, T).

%% Login/refresh/logout bodies are tiny; cap QUIC DATA wait so logs never show ~15s from idle streams alone.
h3_auth_route_body_cap(<<"/api/auth/", _/binary>>, T) ->
    min(T, ?H3_BODY_AUTH_CAP_MS);
h3_auth_route_body_cap(_, T) ->
    T.

header_content_length_bytes(Headers) ->
    Map = h3_req_headers_map(Headers),
    case maps:get(<<"content-length">>, Map, undefined) of
        Bin when is_binary(Bin) ->
            Trim =
                re:replace(Bin, <<"^\\s+|\\s+$">>, <<>>, [{return, binary}, global]),
            try
                {ok, binary_to_integer(Trim)}
            catch
                error:badarg ->
                    undefined
            end;
        _ ->
            undefined
    end.

collect_body(_Conn, _StreamId, Acc, _TimeoutMs, {ok, Cl}) when byte_size(Acc) >= Cl ->
    Acc;
collect_body(_Conn, _StreamId, Acc, TimeoutMs, _Cl) when TimeoutMs =< 0 ->
    Acc;
collect_body(Conn, StreamId, Acc, TimeoutMs, Cl) ->
    T0 = erlang:monotonic_time(millisecond),
    receive
        {quic_h3, Conn, {data, StreamId, Data, true}} ->
            Acc1 = <<Acc/binary, Data/binary>>,
            body_acc_complete(Acc1, Cl);
        {quic_h3, Conn, {data, StreamId, Data, false}} ->
            Acc1 = <<Acc/binary, Data/binary>>,
            case body_acc_complete(Acc1, Cl) of
                complete -> Acc1;
                incomplete ->
                    Elapsed = erlang:monotonic_time(millisecond) - T0,
                    Remaining = TimeoutMs - Elapsed,
                    collect_body(Conn, StreamId, Acc1, Remaining, Cl)
            end
    after TimeoutMs ->
        Acc
    end.

body_acc_complete(Acc, {ok, Cl}) when byte_size(Acc) >= Cl ->
    complete;
body_acc_complete(_Acc, _Cl) ->
    incomplete.

ensure_gun_started() ->
    case application:ensure_all_started(gun) of
        {ok, _} -> ok;
        {error, {already_started, gun}} -> ok;
        _ -> ok
    end.

ensure_quic_started() ->
    _ = application:ensure_all_started(quic),
    _ = application:ensure_all_started(quicer),
    ok.

%% @doc Bind/stack hint for admin UI (matches {@link start_prefer_ipv6_server/2}).
-spec management_listener_bind_stack() -> {Bind :: binary(), Stack :: binary()}.
management_listener_bind_stack() ->
    BindMode = maps:get(h3_udp_bind, pertisk_eproxy_config:get_config(), dual_stack),
    case {os:type(), BindMode} of
        {{unix, linux}, dual_stack} ->
            {<<"[::]:udp">>, <<"dual_stack">>};
        {{unix, _}, dual_stack} ->
            {<<":: + 0.0.0.0">>, <<"split_v4_v6">>};
        {{unix, linux}, split} ->
            {<<":: + 0.0.0.0">>, <<"split_v4_v6">>};
        {{unix, _}, split} ->
            {<<":: + 0.0.0.0">>, <<"split_v4_v6">>};
        {{unix, _}, _} ->
            {<<"[::]:udp">>, <<"dual_stack">>};
        {win32, _} ->
            {<<"0.0.0.0">>, <<"ipv4">>};
        {_, _} ->
            {<<"0.0.0.0">>, <<"ipv4">>}
    end.

start_prefer_ipv6_server(Port, BaseOpts) ->
    start_prefer_ipv6_server(?SERVER, Port, BaseOpts).

start_prefer_ipv6_server(ServerName, Port, BaseOpts) ->
    Config = pertisk_eproxy_config:get_config(),
    BindMode = maps:get(h3_udp_bind, Config, dual_stack),
    case {os:type(), BindMode} of
        {{unix, linux}, split} ->
            start_linux_split_udp(ServerName, Port, BaseOpts);
        {{unix, linux}, dual_stack} ->
            start_linux_dual_stack_udp(ServerName, Port, BaseOpts);
        {{unix, _}, dual_stack} ->
            %% macOS/BSD: single [::] + IPV6_V6ONLY=0 often returns einval; use split v4/v6 instead.
            start_unix_split_udp(ServerName, Port, BaseOpts);
        _ ->
            start_single_udp_listener(ServerName, Port, BaseOpts)
    end.

%% Single [::] dual-stack socket on Linux (same model as pertisk-rproxy / Quinn / Node http3).
start_linux_dual_stack_udp(ServerName, Port, BaseOpts) ->
    QuicBase = maps:get(quic_opts, BaseOpts, #{}),
    Opts = BaseOpts#{
        quic_opts =>
            maps:merge(QuicBase, #{
                socket_backend => socket,
                backend => socket,
                reuseport => false,
                pool_size => 0,
                extra_socket_opts => [inet6, {ipv6_v6only, false}]
            })
    },
    case quic_h3:start_server(ServerName, Port, Opts) of
        {ok, _} = Ok ->
            _ = lager:info(
                "HTTP/3 QUIC listener on udp/[::]:~w (dual-stack, Chrome/Node/Rust compatible)",
                [Port]
            ),
            Ok;
        {error, Reason} ->
            _ = lager:warning(
                "HTTP/3 dual-stack udp/[::]:~w failed (~p); falling back to IPv4-only UDP",
                [Port, Reason]
            ),
            start_single_udp_listener(ServerName, Port, BaseOpts)
    end.

%% Non-Linux Unix: 0.0.0.0 + [::] via gen_udp (OTP socket inet6 bind is einval on macOS).
start_unix_split_udp(ServerName, Port, BaseOpts) ->
    V4Name = v4_server_name(ServerName),
    QuicBase = maps:get(quic_opts, BaseOpts, #{}),
    V4Opts = BaseOpts#{
        quic_opts =>
            maps:merge(QuicBase, #{
                socket_backend => gen_udp,
                reuseport => false,
                pool_size => 0,
                extra_socket_opts => []
            })
    },
    V6Opts = BaseOpts#{
        quic_opts =>
            maps:merge(QuicBase, #{
                socket_backend => gen_udp,
                reuseport => false,
                pool_size => 0,
                extra_socket_opts => [inet6, {ipv6_v6only, true}]
            })
    },
    _ = lager:info(
        "HTTP/3 starting QUIC listeners on udp/:~w (v4=~p gen_udp, v6=~p gen_udp, non-Linux dual_stack)",
        [Port, V4Name, ServerName]
    ),
    V4Result = quic_h3:start_server(V4Name, Port, V4Opts),
    V6Result = quic_h3:start_server(ServerName, Port, V6Opts),
    case {V4Result, V6Result} of
        {{ok, _}, {ok, V6Pid}} ->
            lager:info(
                "HTTP/3 QUIC listeners ready on udp/0.0.0.0:~w and udp/[::]:~w",
                [Port, Port]
            ),
            {ok, V6Pid};
        {{ok, V4Pid}, {error, V6Reason}} ->
            lager:warning(
                "HTTP/3 QUIC IPv6 listener failed on udp/[::]:~w (~p); using IPv4 QUIC only",
                [Port, V6Reason]
            ),
            {ok, V4Pid};
        {{error, V4Reason}, {ok, V6Pid}} ->
            lager:warning(
                "HTTP/3 QUIC IPv4 listener failed on udp/0.0.0.0:~w (~p); using IPv6 QUIC only",
                [Port, V4Reason]
            ),
            {ok, V6Pid};
        {{error, V4Reason}, {error, V6Reason}} ->
            lager:warning(
                "HTTP/3 QUIC split bind failed (v4=~p, v6=~p); trying IPv4-only UDP",
                [V4Reason, V6Reason]
            ),
            start_single_udp_listener(ServerName, Port, BaseOpts)
    end.

start_single_udp_listener(ServerName, Port, BaseOpts) ->
    case quic_h3:start_server(ServerName, Port, BaseOpts) of
        {ok, _} = Ok ->
            Ok;
        {error, Reason} ->
            {error, {failed_quic_udp_listener, Reason}}
    end.

%% Legacy Linux: separate IPv4 gen_udp + IPv6 socket (reuseport).
start_linux_split_udp(ServerName, Port, BaseOpts) ->
    case os:type() of
        {unix, linux} ->
            V4Name = v4_server_name(ServerName),

            QuicBase = maps:get(quic_opts, BaseOpts, #{}),
            %% IPv4 first: gen_udp + inet is the well-tested erlang_quic listener path.
            V4Opts = BaseOpts#{
                quic_opts =>
                    maps:merge(QuicBase, #{
                        socket_backend => gen_udp,
                        reuseport => true,
                        pool_size => 0,
                        extra_socket_opts => []
                    })
            },
            %% Native IPv6 only (::, V6ONLY=1). Do not use V6ONLY=0 when v4 is also bound.
            V6Opts = BaseOpts#{
                quic_opts =>
                    maps:merge(QuicBase, #{
                        socket_backend => socket,
                        backend => socket,
                        reuseport => true,
                        pool_size => 0,
                        extra_socket_opts => [inet6, {ipv6_v6only, true}]
                    })
            },

            _ = lager:info(
                "HTTP/3 starting QUIC listeners on udp/:~w (v4=~p gen_udp, v6=~p socket)",
                [Port, V4Name, ServerName]
            ),

            %% Bind IPv4 (0.0.0.0) before IPv6 ([::]) — some kernels are picky about order.
            V4Ok =
                case quic_h3:start_server(V4Name, Port, V4Opts) of
                    {ok, _} ->
                        lager:info("HTTP/3 QUIC IPv4 listener ready on udp/0.0.0.0:~w", [Port]),
                        true;
                    {error, V4Reason} ->
                        lager:error(
                            "HTTP/3 QUIC IPv4 listener failed on udp/0.0.0.0:~w: ~p "
                            "(falling back to dual-stack [::] only for IPv4+IPv6)",
                            [Port, V4Reason]
                        ),
                        false
                end,
            V6OptsFinal =
                case V4Ok of
                    true ->
                        V6Opts;
                    false ->
                        %% Single [::] socket with V6ONLY=0 when dedicated IPv4 bind failed.
                        BaseOpts#{
                            quic_opts =>
                                maps:merge(QuicBase, #{
                                    socket_backend => socket,
                                    backend => socket,
                                    reuseport => false,
                                    pool_size => 0,
                                    extra_socket_opts => [inet6, {ipv6_v6only, false}]
                                })
                        }
                end,
            case quic_h3:start_server(ServerName, Port, V6OptsFinal) of
                {ok, Pid} ->
                    case V4Ok of
                        true ->
                            lager:info("HTTP/3 QUIC IPv6 listener ready on udp/[::]:~w", [Port]);
                        false ->
                            lager:info(
                                "HTTP/3 QUIC listener ready on udp/[::]:~w (dual-stack, no separate 0.0.0.0 bind)",
                                [Port]
                            )
                    end,
                    {ok, Pid};
                {error, V6Reason} ->
                    _ = catch quic_h3:stop_server(V4Name),
                    {error, {failed_quic_udp_listener_v6, V6Reason}}
            end;
        _ ->
            %% Non-linux: keep existing behaviour.
            case quic_h3:start_server(ServerName, Port, BaseOpts) of
                {ok, _} = Ok ->
                    Ok;
                {error, Reason} ->
                    {error, {failed_quic_udp_listener, Reason}}
            end
    end.

v4_server_name(?SERVER) -> ?SERVER_V4;
v4_server_name(?PROBE_SERVER) -> ?PROBE_SERVER_V4;
v4_server_name(Other) -> Other.

load_cert_and_key(Config) ->
    CertPath = maps:get(tls_cert_file, Config, "priv/tls/listener.pem"),
    KeyPath = maps:get(tls_key_file, Config, "priv/tls/listener.key"),
    case {file:read_file(CertPath), file:read_file(KeyPath)} of
        {{ok, CertPem}, {ok, KeyPem}} ->
            decode_listener_pem(CertPem, KeyPem, CertPath, KeyPath);
        {{error, enoent}, _} ->
            {error, {missing_tls_file, cert, CertPath}};
        {_, {error, enoent}} ->
            {error, {missing_tls_file, key, KeyPath}};
        {{error, CErr}, _} ->
            {error, {read_cert_failed, CertPath, CErr}};
        {_, {error, KErr}} ->
            {error, {read_key_failed, KeyPath, KErr}}
    end.

decode_listener_pem(CertPem, KeyPem, CertPath, KeyPath) ->
    try
        CertDers = [
            D
         || {'Certificate', D, not_encrypted} <- public_key:pem_decode(CertPem)
        ],
        case CertDers of
            [] ->
                {error, {invalid_listener_pem, CertPath, KeyPath}};
            [Leaf | Chain] ->
                [KeyEntry | _] = public_key:pem_decode(KeyPem),
                {ok, {Leaf, public_key:pem_entry_decode(KeyEntry), Chain}}
        end
    catch
        _:_ ->
            {error, {invalid_listener_pem, CertPath, KeyPath}}
    end.

%% Leaf in `cert`, intermediates in `cert_chain` (Chrome QUIC is strict; TCP certfile sends the full PEM).
tls_server_opts(CertDer, KeyTerm, []) ->
    #{cert => CertDer, key => KeyTerm};
tls_server_opts(CertDer, KeyTerm, Chain) ->
    #{cert => CertDer, key => KeyTerm, cert_chain => Chain}.

%% Reinforce HTTP/3 on responses (Chrome caches Alt-Svc from the first successful H3 response).
maybe_add_h3_alt_svc(Host, Headers) ->
    case pertisk_eproxy_handler:site_advertise_http3(Host) of
        true ->
            H = headers_without(Headers, [<<"alt-svc">>]),
            H ++ [{<<"alt-svc">>, pertisk_eproxy_alt_svc:header_value()}];
        false ->
            Headers
    end.

headers_without(Headers, DropKeys) ->
    DropLC = [string:lowercase(D) || D <- DropKeys],
    [
        {K, V}
     || {K, V} <- Headers,
        not lists:member(string:lowercase(K), DropLC)
    ].
