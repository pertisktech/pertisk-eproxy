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
                    SniCerts = load_sni_certs(Config),
                    do_start_gateway(Port, CertDer, KeyTerm, CertChain, SniCerts);
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, _} = Err ->
            Err
    end.

do_start_gateway(Port, CertDer, KeyTerm, CertChain, SniCerts) ->
    Config = pertisk_eproxy_config:get_config(),
    CertPath = case pertisk_eproxy_tls_paths:resolve_cert_file(Config) of
        undefined -> pertisk_eproxy_tls_paths:default_cert_file();
        P -> P
    end,
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
    _ = case maps:size(SniCerts) of
        0 -> ok;
        N -> lager:info("HTTP/3 listener: loaded ~p SNI certificate override(s)", [N])
    end,
    BaseOpts = maps:merge(
        tls_server_opts(CertDer, KeyTerm, CertChain, SniCerts),
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
                "Rebuild with erlang_quic 1.4.0 or newer."
            ),
            {error, incompatible_quic_qpack}
    end.

qpack_ric0_prefix_ok() ->
    case code:which(quic_qpack) of
        non_existing ->
            lager:error("quic_qpack module missing from release code path"),
            false;
        BeamFile ->
            try
                %% Encode a static-only block; RFC 9204 requires RIC=0 and Base=0.
                Encoded = quic_qpack:encode([{<<":status">>, <<"200">>}]),
                case Encoded of
                    <<0, 0, _/binary>> ->
                        lager:debug("quic_qpack RIC=0 ok (~s)", [BeamFile]),
                        true;
                    Bad ->
                        lager:error(
                            "quic_qpack bad prefix ~p from ~s (expected erlang_quic 1.4.0+)",
                            [Bad, BeamFile]
                        ),
                        false
                end
            catch
                C:R:St ->
                    lager:error("quic_qpack encode failed ~p:~p ~p", [C, R, St]),
                    false
            end
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
        tls_server_opts(CertDer, KeyTerm, CertChain, #{}),
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
                _ = h3_reply_status(
                    H3Conn,
                    StreamId,
                    404,
                    [{<<"content-type">>, <<"text/plain">>}],
                    <<"No route found for host: ", LogHost/binary>>
                ),
                log_h3_access(LogHost, Method, PathOnly, 404, T0, <<>>),
                ok;
            {ok, #{upstream_path := UpPath, backend := BackendName}} ->
                ClientIp = client_ip_h3(H3Conn, Headers),
                ProxyCtx = #{
                    method => Method,
                    host => LogHost,
                    path => PathOnly,
                    up_path => UpPath,
                    qs => Qs,
                    headers => Headers,
                    body => Body,
                    client_ip => ClientIp,
                    backend => BackendName
                },
                case h3_proxy_for_backend(ProxyCtx) of
                    {error, no_healthy_upstream} ->
                        pertisk_eproxy_metrics:inc_request(LogHost, <<"502">>, <<"h3">>),
                        reply_502_plain(H3Conn, StreamId),
                        log_h3_access(LogHost, Method, PathOnly, 502, T0, <<>>),
                        ok;
                    {ok, UpstreamAddr, ProxyResult} ->
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
                                H3Headers0 = maybe_add_h3_alt_svc(LogHost, RespHeaders),
                                {H3Headers, RespOut} = pertisk_eproxy_compression:maybe_compress_h3(
                                    Status,
                                    Headers,
                                    H3Headers0,
                                    RespBin
                                ),
                                %% RFC 9114 §4.3.2: HEAD responses MUST NOT include a message body.
                                RespData =
                                    case normalize_h3_method(Method) of
                                        <<"HEAD">> -> <<>>;
                                        _ -> RespOut
                                    end,
                                _ = h3_reply_status(H3Conn, StreamId, Status, H3Headers, RespData),
                                UpstreamLog =
                                    case pertisk_eproxy_config:is_management_upstream_addr(UpstreamAddr) of
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
                                    "h3 upstream failed: ~p host=~s path=~s upstream=~s",
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
            case h3_send_failed_reason(Reason) of
                connection_gone ->
                    log_h3_access(LogHost, Method, PathOnly, 0, T0, <<>>),
                    ok;
                _ ->
                    lager:error(
                        "h3 handle_request crash class=~p reason=~p host=~s path=~s stack=~p",
                        [Class, Reason, LogHost, Path, Stack]
                    ),
                    _ = h3_reply_status(
                        H3Conn,
                        StreamId,
                        500,
                        [{<<"content-type">>, <<"text/plain">>}],
                        <<"Internal Server Error">>
                    ),
                    log_h3_access(LogHost, Method, PathOnly, 500, T0, <<>>),
                    ok
            end
    end.

%% Client reset or QUIC connection closed before we finish the response.
h3_send_response(H3Conn, StreamId, Status, Headers) ->
    case catch quic_h3:send_response(H3Conn, StreamId, Status, Headers) of
        ok -> ok;
        {'EXIT', {noproc, _}} -> {error, connection_gone};
        {'EXIT', Reason} -> {error, Reason}
    end.

h3_send_data(H3Conn, StreamId, Data, Fin) ->
    case catch quic_h3:send_data(H3Conn, StreamId, Data, Fin) of
        ok -> ok;
        {'EXIT', {noproc, _}} -> {error, connection_gone};
        {'EXIT', Reason} -> {error, Reason}
    end.

h3_reply_status(H3Conn, StreamId, Status, Headers, Body) ->
    H3Headers = pertisk_eproxy_response_headers:merge_h3(Headers),
    case h3_send_response(H3Conn, StreamId, Status, H3Headers) of
        ok ->
            %% Always FIN the stream (required for HEAD with empty body too).
            h3_send_data(H3Conn, StreamId, Body, true);
        {error, connection_gone} ->
            {error, connection_gone};
        {error, _} = Err ->
            Err
    end.

h3_send_failed_reason({noproc, {gen_statem, call, _}}) ->
    connection_gone;
h3_send_failed_reason({noproc, _}) ->
    connection_gone;
h3_send_failed_reason(_) ->
    other.

reply_502_plain(H3Conn, StreamId) ->
    h3_reply_status(
        H3Conn,
        StreamId,
        502,
        [{<<"content-type">>, <<"text/plain">>}],
        <<"Bad Gateway">>
    ).

%% @doc Handle `/api/realtime-sse` over HTTP/3 by streaming SSE events directly.
%% gun:await_body cannot forward an indefinite SSE stream, so we replicate the
%% Local admin handler processing for H3 requests.
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

%% Keep H3 sessions stable across browser idle windows and NAT/LB churn.
-define(H3_IDLE_TIMEOUT_SECS_DEFAULT, 1800).
-define(H3_IDLE_TIMEOUT_SECS_MIN, 900).
-define(H3_KEEPALIVE_SECS_DEFAULT, 20).
-define(H3_SAFE_MAX_UDP_PAYLOAD_SIZE, 1200).

%% HTTP/3 SETTINGS sent to clients.
%% Force default dynamic QPACK for Chromium compatibility.
h3_http_settings(Config) ->
    case maps:get(h3_qpack_static, Config, false) of
        true ->
            lager:warning(
                "h3_qpack_static=true is deprecated and ignored; using default dynamic QPACK for Chromium compatibility",
                []
            );
        _ ->
            ok
    end,
    #{}.

%% Admin/management backends: skip LB health gate and gun loopback (in-process HTTP/3).
h3_proxy_for_backend(#{
    method := Method,
    host := LogHost,
    path := PathOnly,
    up_path := UpPath,
    qs := Qs,
    headers := Headers,
    body := Body,
    client_ip := ClientIp,
    backend := BackendName
}) ->
    case pertisk_eproxy_config:backend_is_management_only(BackendName) of
        true ->
            Mgmt = pertisk_eproxy_config:management_loopback_upstream_bin(),
            Result =
                pertisk_eproxy_h3_local_admin:try_dispatch(
                    Method, LogHost, PathOnly, Qs, Headers, Body, ClientIp
                ),
            {ok, Mgmt, Result};
        false ->
            case pertisk_eproxy_backend:pick_upstream(BackendName, ClientIp) of
                {error, no_healthy_upstream} ->
                    {error, no_healthy_upstream};
                {ok, UpstreamAddr} ->
                    Result =
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
                    {ok, UpstreamAddr, Result}
            end
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
    case pertisk_eproxy_config:is_management_upstream_addr(UpstreamAddr) of
        true ->
            Loopback = pertisk_eproxy_config:management_loopback_upstream_bin(),
            case pertisk_eproxy_h3_local_admin:try_dispatch(
                Method, LogHost, PathOnly, Qs, Headers, Body, ClientIp
            ) of
                {ok, Status, RespHeaders, RespBody} ->
                    {ok, Status, gun_resp_headers_to_h3(RespHeaders), RespBody};
                {error, unsupported} ->
                    proxy_via_gun(
                        Method, LogHost, UpPath, Qs, Loopback, Headers, Body, ClientIp
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
    IdleSecs0 =
        case maps:get(h3_idle_timeout_secs, Config, undefined) of
            IdleS when is_integer(IdleS), IdleS >= 0 ->
                IdleS;
            _ ->
                ?H3_IDLE_TIMEOUT_SECS_DEFAULT
        end,
    IdleSecs =
        case IdleSecs0 of
            0 -> 0;
            _ -> max(?H3_IDLE_TIMEOUT_SECS_MIN, IdleSecs0)
        end,
    KeepSecs0 =
        case maps:get(h3_keepalive_interval_secs, Config, undefined) of
            KeepS when is_integer(KeepS), KeepS >= 0 ->
                KeepS;
            _ ->
                ?H3_KEEPALIVE_SECS_DEFAULT
        end,
    KeepSecs =
        case {IdleSecs, KeepSecs0} of
            {0, _} -> 0;
            {_, 0} -> 0;
            {I, K} ->
                %% Keep keepalive below idle timeout so periodic PINGs refresh path state.
                min(K, max(5, I div 3))
        end,
    _ =
        case {IdleSecs0, IdleSecs} of
            {I0, ClampedIdle} when I0 =/= 0, I0 < ClampedIdle ->
                lager:warning(
                    "h3_idle_timeout_secs=~w too low for stable browser idle behavior; clamped to ~w",
                    [I0, ClampedIdle]
                );
            _ ->
                ok
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
            %% A finished stream must yield the accumulated binary body, not the
            %% completion sentinel used for intermediate length checks.
            Acc1;
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
    case application:ensure_all_started(quic) of
        {ok, _} ->
            ok;
        {error, {already_started, quic}} ->
            ok;
        {error, Reason} ->
            lager:error(
                "quic application failed to start (~p); HTTP/3 requires erlang_quic in the release",
                [Reason]
            ),
            {error, Reason}
    end.

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
    case ingress_default_listener_tls(Config) of
        {ok, Material} ->
            {ok, Material};
        error ->
            CertPath = case pertisk_eproxy_tls_paths:resolve_cert_file(Config) of
                undefined -> {error, {missing_tls_file, cert, no_listener_cert}};
                Cert -> Cert
            end,
            KeyPath = case pertisk_eproxy_tls_paths:resolve_key_file(Config) of
                undefined -> {error, {missing_tls_file, key, no_listener_key}};
                Key -> Key
            end,
            case {CertPath, KeyPath} of
                {{error, _}, _} ->
                    CertPath;
                {_, {error, _}} ->
                    KeyPath;
                {CP, KP} ->
                    load_cert_and_key_files(CP, KP)
            end
    end.

%% Prefer Kubernetes Ingress TLS (full chain from tls.crt) over packaged listener.pem.
ingress_default_listener_tls(Config) ->
    case pertisk_ingress_env:enabled() of
        false ->
            error;
        true ->
            Sites = maps:get(sites, Config, []),
            ingress_default_listener_tls_sites(Sites)
    end.

ingress_default_listener_tls_sites([]) ->
    error;
ingress_default_listener_tls_sites([Site | Rest]) ->
    Host = maps:get(host, Site, undefined),
    case ingress_host_tls_material(Host) of
        {ok, Material} ->
            lager:info("HTTP/3 default TLS from ingress host ~s", [Host]),
            {ok, Material};
        error ->
            ingress_default_listener_tls_sites(Rest)
    end.

ingress_host_tls_material(Host) ->
    case pertisk_ingress_tls:paths_for_host(Host) of
        {ok, {CertPath, KeyPath}} ->
            load_cert_and_key_files(CertPath, KeyPath);
        error ->
            case pertisk_ingress_tls:lookup(Host) of
                {ok, Entry} ->
                    case pertisk_ingress_tls:decode_entry(Entry) of
                        {ok, #{cert := CertDer, private_key := KeyTerm, cert_chain := Chain}} ->
                            {ok, {CertDer, KeyTerm, Chain}};
                        _ ->
                            error
                    end;
                error ->
                    error
            end
    end.

load_cert_and_key_files(CertPath, KeyPath) when is_list(CertPath), is_list(KeyPath) ->
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
tls_server_opts(CertDer, KeyTerm, Chain, SniCerts) ->
    Base = case Chain of
        [] -> #{cert => CertDer, key => KeyTerm};
        _ -> #{cert => CertDer, key => KeyTerm, cert_chain => Chain}
    end,
    case maps:size(SniCerts) of
        0 -> Base;
        _ -> Base#{sni_certs => SniCerts}
    end.

load_sni_certs(Config) ->
    Sites = maps:get(sites, Config, []),
    DbPath = pertisk_eproxy_config:db_file(),
    DbAcc = case pertisk_eproxy_db:list_certificates(DbPath) of
        {ok, Rows} ->
            RowsById = maps:from_list([
                {integer_to_binary(maps:get(id, Row)), Row}
             || Row <- Rows
            ]),
            RowsByName = maps:from_list([
                {sni_ref_to_binary(maps:get(name, Row, <<>>)), Row}
             || Row <- Rows
            ]),
            lists:foldl(
                fun(Site, Acc) ->
                    case {site_host_key(maps:get(host, Site, undefined)), maps:get(certificate, Site, undefined)} of
                        {undefined, _} ->
                            Acc;
                        {_, undefined} ->
                            Acc;
                        {HostKey, CertRef} ->
                            case resolve_sni_cert_entry(CertRef, RowsById, RowsByName) of
                                {ok, Entry} -> maps:put(HostKey, Entry, Acc);
                                _ -> Acc
                            end
                    end
                end,
                #{},
                Sites
            );
        _ ->
            #{}
    end,
    merge_ingress_sni_certs(Sites, DbAcc).

merge_ingress_sni_certs(Sites, Acc) ->
    case pertisk_ingress_env:enabled() of
        false ->
            Acc;
        true ->
            lists:foldl(
                fun(Site, A) ->
                    case site_host_key(maps:get(host, Site, undefined)) of
                        undefined ->
                            A;
                        HostKey ->
                            case maps:is_key(HostKey, A) of
                                true ->
                                    A;
                                false ->
                                    Host = maps:get(host, Site, undefined),
                                    case ingress_sni_tls_entry(Host) of
                                        {ok, Decoded} ->
                                            maps:put(HostKey, Decoded, A);
                                        error ->
                                            A
                                    end
                            end
                    end
                end,
                Acc,
                Sites
            )
    end.

ingress_sni_tls_entry(Host) ->
    case pertisk_ingress_tls:paths_for_host(Host) of
        {ok, {CertPath, KeyPath}} ->
            case load_cert_and_key_files(CertPath, KeyPath) of
                {ok, {CertDer, KeyTerm, Chain}} ->
                    {ok, #{
                        cert => CertDer,
                        cert_chain => Chain,
                        private_key => KeyTerm
                    }};
                _ ->
                    ingress_sni_tls_entry_from_store(Host)
            end;
        error ->
            ingress_sni_tls_entry_from_store(Host)
    end.

ingress_sni_tls_entry_from_store(Host) ->
    case pertisk_ingress_tls:lookup(Host) of
        {ok, Entry} ->
            pertisk_ingress_tls:decode_entry(Entry);
        error ->
            error
    end.

resolve_sni_cert_entry(CertRef, RowsById, RowsByName) ->
    RefBin = sni_ref_to_binary(CertRef),
    Row = case maps:get(RefBin, RowsById, undefined) of
        undefined -> maps:get(RefBin, RowsByName, undefined);
        ById -> ById
    end,
    decode_sni_cert_row(Row).

decode_sni_cert_row(#{cert_pem := CertPem0, key_pem := KeyPem0}) ->
    CertPem = sni_text_bin(CertPem0),
    KeyPem = sni_text_bin(KeyPem0),
    case {CertPem, KeyPem} of
        {undefined, _} -> {error, missing_cert_pem};
        {_, undefined} -> {error, missing_key_pem};
        {CertPemBin, KeyPemBin} ->
            try
                CertDers = [
                    D
                 || {'Certificate', D, not_encrypted} <- public_key:pem_decode(CertPemBin)
                ],
                case CertDers of
                    [] ->
                        {error, invalid_cert_pem};
                    [Leaf | Chain] ->
                        [KeyEntry | _] = public_key:pem_decode(KeyPemBin),
                        {ok, #{
                            cert => Leaf,
                            cert_chain => Chain,
                            private_key => public_key:pem_entry_decode(KeyEntry)
                        }}
                end
            catch
                _:_ -> {error, invalid_tls_material}
            end
    end;
decode_sni_cert_row(_) ->
    {error, missing_row}.

site_host_key(undefined) ->
    undefined;
site_host_key(null) ->
    undefined;
site_host_key(Host) when is_list(Host) ->
    site_host_key(unicode:characters_to_binary(Host, utf8));
site_host_key(Host) when is_binary(Host) ->
    Trim = re:replace(Host, <<"^\\s+|\\s+$">>, <<>>, [{return, binary}, global]),
    case Trim of
        <<>> -> undefined;
        _ -> string:lowercase(Trim)
    end;
site_host_key(_) ->
    undefined.

sni_ref_to_binary(undefined) -> undefined;
sni_ref_to_binary(null) -> undefined;
sni_ref_to_binary(V) when is_binary(V) -> V;
sni_ref_to_binary(V) when is_list(V) -> unicode:characters_to_binary(V, utf8);
sni_ref_to_binary(V) when is_integer(V) -> integer_to_binary(V);
sni_ref_to_binary(_) -> undefined.

sni_text_bin(undefined) -> undefined;
sni_text_bin(null) -> undefined;
sni_text_bin(V) when is_binary(V) -> V;
sni_text_bin(V) when is_list(V) -> unicode:characters_to_binary(V, utf8);
sni_text_bin(_) -> undefined.

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
