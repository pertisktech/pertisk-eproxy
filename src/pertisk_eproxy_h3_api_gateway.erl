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
-define(SERVER_V6, pertisk_eproxy_h3_api_v6).
-define(PROBE_SERVER_V6, pertisk_eproxy_h3_probe_v6).
%% Actual main-gateway UDP bind (set on successful start; used by {@link management_listener_bind_stack/0}).
-define(H3_GATEWAY_LISTEN_PT, {pertisk_eproxy, h3_api_gateway_udp_listen}).
%% Max wait per read_request_body (H3 client request DATA). Was a flat 15s and matched ~15003ms access-log timings for small API POSTs (e.g. /api/auth/refresh).
-define(H3_BODY_TIMEOUT_UNKNOWN_CL_MS, 3500).
-define(H3_BODY_TIMEOUT_SMALL_POST_MS, 4000).
-define(H3_BODY_TIMEOUT_LARGE_CAP_MS, 120000).
-define(H3_BODY_AUTH_CAP_MS, 3000).
-define(REQUEST_TIMEOUT, 60000).
-define(CONNECT_TIMEOUT, 10000).
%% Offer RFC 9114 `h3` first, then draft ALPNs still used by some stacks (cf. Alt-Svc `h3-29`).
-define(H3_QUIC_ALPN, [<<"h3">>, <<"h3-29">>, <<"h3-28">>]).

start(Config) ->
    _ = pertisk_h3_transport:ensure_deps_started(),
    _ = ensure_gun_started(),
    ListenerBackend = maps:get(h3_listener_backend, Config, gen_udp),
    Port = case maps:get(quic_port, Config, undefined) of
        P when is_integer(P), P > 0 -> P;
        _ -> maps:get(https_port, Config, 443)
    end,
    {CertDer, KeyTerm} = load_cert_and_key(Config),
    BaseOpts = #{
        cert => CertDer,
        key => KeyTerm,
        sni_cert_selector => pertisk_eproxy_app:quic_sni_cert_selector(Config),
        %% quic_listener_sup_sup uses `1 + maps:get(pool_size, Opts, 1)' — default omits
        %% pool_size ⇒ two UDP listeners + reuseport on the same port (see lsof).
        quic_opts => #{pool_size => 0, alpn => ?H3_QUIC_ALPN},
        settings => #{
            %% Force static QPACK to avoid dynamic table/base calculation
            %% interoperability failures seen from external clients.
            qpack_max_table_capacity => 0,
            qpack_blocked_streams => 0
        },
        listener_backend => ListenerBackend,
        h3_quic_ipv4_only => maps:get(h3_quic_ipv4_only, Config, false),
        handler => ?MODULE
    },
    start_prefer_ipv6_server(Port, BaseOpts).

stop() ->
    _ = catch persistent_term:erase(?H3_GATEWAY_LISTEN_PT),
    stop_h3_server_name(?SERVER),
    stop_h3_server_name(?SERVER_V6),
    ok.

start_probe(Config) ->
    _ = pertisk_h3_transport:ensure_deps_started(),
    _ = ensure_gun_started(),
    BasePort = case maps:get(quic_port, Config, undefined) of
        P when is_integer(P), P > 0 -> P;
        _ -> maps:get(https_port, Config, 443)
    end,
    ProbePort = maps:get(h3_probe_port, Config, BasePort + 1),
    {CertDer, KeyTerm} = load_cert_and_key(Config),
    ProbeBackend = maps:get(h3_listener_backend, Config, gen_udp),
    ProbeOpts = #{
        cert => CertDer,
        key => KeyTerm,
        sni_cert_selector => pertisk_eproxy_app:quic_sni_cert_selector(Config),
        quic_opts => #{pool_size => 0, alpn => ?H3_QUIC_ALPN},
        listener_backend => ProbeBackend,
        h3_quic_ipv4_only => maps:get(h3_quic_ipv4_only, Config, false),
        handler => pertisk_eproxy_h3_probe_handler
    },
    start_prefer_ipv6_server(?PROBE_SERVER, ProbePort, ProbeOpts).

stop_probe() ->
    stop_h3_server_name(?PROBE_SERVER),
    stop_h3_server_name(?PROBE_SERVER_V6),
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
                H404 = maps:merge(
                    h3_response_edge_defaults(),
                    #{<<"content-type">> => <<"text/plain">>}
                ),
                _ = safe_h3_send_response(
                    H3Conn, StreamId, 404, maps:to_list(H404)
                ),
                _ = safe_h3_send_data(
                    H3Conn,
                    StreamId,
                    <<"No route found for host: ", LogHost/binary>>,
                    true
                ),
                log_h3_access(LogHost, Method, PathOnly, 404, T0, <<>>),
                ok;
            {ok, #{upstream_path := UpPath, backend := BackendName}} ->
                ClientIp = pertisk_h3_transport:client_peer_ip(H3Conn, Headers),
                case pertisk_eproxy_backend:pick_upstream(BackendName, ClientIp) of
                    {error, no_healthy_upstream} ->
                        pertisk_eproxy_metrics:inc_request(LogHost, <<"502">>, <<"h3">>),
                        reply_502_plain(H3Conn, StreamId),
                        log_h3_access(LogHost, Method, PathOnly, 502, T0, <<>>),
                        ok;
                    {ok, UpstreamAddr} ->
                        case proxy_via_gun(
                            Method, LogHost, UpPath, Qs, UpstreamAddr, Headers, Body, ClientIp
                        ) of
                            {ok, Status0, RespHeaders, RespBody} ->
                                Status = gun_response_status_int(Status0),
                                StatusBin = integer_to_binary(Status),
                                pertisk_eproxy_metrics:inc_request(LogHost, StatusBin, <<"h3">>),
                                RespBin0 = safe_iolist_to_binary(RespBody),
                                %% RFC 9110 §9.3.2: HEAD responses must not include a message body (headers may mirror GET).
                                RespBin =
                                    case normalize_h3_method(Method) of
                                        <<"HEAD">> -> <<>>;
                                        _ -> RespBin0
                                    end,
                                ok = pertisk_eproxy_metrics:record_proxy_bytes(
                                    LogHost, byte_size(Body), byte_size(RespBin)
                                ),
                                ok = pertisk_eproxy_backend:done_upstream(
                                    BackendName, UpstreamAddr, ok
                                ),
                                H3Hdrs0 = gun_resp_headers_to_h3(RespHeaders),
                                H3HdrsMap = maps:from_list(H3Hdrs0),
                                H3HdrsMergedMap = pertisk_eproxy_security_headers:merge_response_headers(
                                    LogHost, H3HdrsMap, <<"https">>
                                ),
                                H3HdrsFinalMap = maps:merge(
                                    h3_response_edge_defaults(), H3HdrsMergedMap
                                ),
                                H3Hdrs = maps:to_list(H3HdrsFinalMap),
                                _ = safe_h3_send_response(H3Conn, StreamId, Status, H3Hdrs),
                                _ = safe_h3_send_data(H3Conn, StreamId, RespBin, true),
                                log_h3_access(LogHost, Method, PathOnly, Status, T0, UpstreamAddr),
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
            H500 = maps:merge(
                h3_response_edge_defaults(),
                #{<<"content-type">> => <<"text/plain">>}
            ),
            _ = catch pertisk_h3_transport:send_response(
                H3Conn, StreamId, 500, maps:to_list(H500)
            ),
            _ = catch pertisk_h3_transport:send_data(H3Conn, StreamId, <<"Internal Server Error">>, true),
            log_h3_access(LogHost, Method, PathOnly, 500, T0, <<>>),
            ok
    end.

reply_502_plain(H3Conn, StreamId) ->
    H502 = maps:merge(
        h3_response_edge_defaults(),
        #{<<"content-type">> => <<"text/plain">>}
    ),
    _ = safe_h3_send_response(
        H3Conn, StreamId, 502, maps:to_list(H502)
    ),
    _ = safe_h3_send_data(H3Conn, StreamId, <<"Bad Gateway">>, true),
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

proxy_via_gun(MethodBin, OrigHost, UpstreamPath, Qs, UpstreamAddr, H3Headers, Body, ClientIp) ->
    {UpHost, UpPort, Transport} = pertisk_eproxy_proxy_http:parse_upstream(UpstreamAddr),
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

%% @doc Same edge fields as TCP {@link cowboy}: {@code date}, {@code server}, {@code alt-svc}.
%%
%% {@link gun_resp_headers_to_h3/1} drops upstream {@code date}/{@code server} so we
%% re-apply defaults; security/site maps still win via {@code maps:merge/2} order.
-spec h3_response_edge_defaults() -> map().
h3_response_edge_defaults() ->
    Cfg = pertisk_eproxy_config:get_config(),
    Alt =
        case pertisk_h3_alt_svc:advertised_port(Cfg, undefined) of
            P when is_integer(P), P > 0 ->
                #{<<"alt-svc">> => pertisk_h3_alt_svc:header_value(P)};
            _ ->
                #{}
        end,
    maps:merge(
        #{
            <<"date">> => cow_date:rfc1123(calendar:universal_time()),
            <<"server">> => <<"Cowboy">>
        },
        Alt
    ).

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

safe_h3_send_response(H3Conn, StreamId, Status, Headers) ->
    try pertisk_h3_transport:send_response(H3Conn, StreamId, Status, Headers) of
        Result -> Result
    catch
        exit:normal -> ok;
        exit:Reason -> {error, Reason};
        Class:Reason -> {error, {Class, Reason}}
    end.

safe_h3_send_data(H3Conn, StreamId, Data, Fin) ->
    try pertisk_h3_transport:send_data(H3Conn, StreamId, Data, Fin) of
        Result -> Result
    catch
        exit:normal -> ok;
        exit:Reason -> {error, Reason};
        Class:Reason -> {error, {Class, Reason}}
    end.

log_h3_access(Host, Method, Path, Status, T0, Upstream) ->
    Dt = max(0, erlang:monotonic_time(millisecond) - T0),
    catch pertisk_eproxy_access_log:log_proxy(Host, Method, Path, Status, Dt, 'HTTP/3', Upstream).

read_request_body(Conn, StreamId, Method0, Headers, PathOnly) ->
    Method = normalize_h3_method(Method0),
    case Method of
        <<"GET">> -> <<>>;
        <<"HEAD">> -> <<>>;
        _ -> read_request_body_post(Conn, StreamId, Headers, PathOnly)
    end.

read_request_body_post(Conn, StreamId, Headers, PathOnly) ->
    TimeoutMs = h3_body_collect_timeout_ms(Headers, PathOnly),
    ExpectCL =
        case header_content_length_bytes(Headers) of
            {ok, N} when is_integer(N), N >= 0 -> N;
            _ -> undefined
        end,
    case pertisk_h3_transport:set_stream_handler(Conn, StreamId, self()) of
        {ok, Buffered} ->
            Body = pertisk_h3_transport:collect_request_body(
                Conn, StreamId, chunks_to_binary(Buffered), TimeoutMs, ExpectCL
            ),
            ok = h3_request_stream_body_cleanup(Conn, StreamId),
            Body;
        ok ->
            Body = pertisk_h3_transport:collect_request_body(
                Conn, StreamId, <<>>, TimeoutMs, ExpectCL
            ),
            ok = h3_request_stream_body_cleanup(Conn, StreamId),
            Body;
        _ ->
            <<>>
    end.

%% After a full request body (often via {@code content-length}), Chrome may send
%% a trailing DATA+FIN on its own schedule. We must not leave `{@code quic_h3,...}'
%% messages in this process while calling {@code gun:await}, and we should
%% unregister so the H3 connection can finish the request stream cleanly.
h3_request_stream_body_cleanup(Conn, StreamId) ->
    h3_flush_stream_data_mailbox(Conn, StreamId),
    _ = catch quic_h3:unset_stream_handler(Conn, StreamId),
    ok.

h3_flush_stream_data_mailbox(Conn, StreamId) ->
    receive
        {quic_h3, Conn, {data, StreamId, _, _}} ->
            h3_flush_stream_data_mailbox(Conn, StreamId)
    after 0 ->
        ok
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

ensure_gun_started() ->
    case application:ensure_all_started(gun) of
        {ok, _} -> ok;
        {error, {already_started, gun}} -> ok;
        _ -> ok
    end.

%% @doc Stop UDP H3 listener for `Name` on all built-in backends (safe if env switched since start).
stop_h3_server_name(Name) ->
    _ = catch pertisk_h3_transport_erlang_quic:stop_server(Name),
    _ = catch pertisk_h3_transport_quicer_stub:stop_server(Name),
    ok.

%% @doc Bind/stack for admin UI and startup logs.
%%
%% After the main HTTP/3 gateway has started successfully, reflects the
%% effective UDP bind (e.g. IPv4-only fallback on Linux). Before start or for unknown state,
%% falls back to OS-level defaults.
-spec management_listener_bind_stack() -> {Bind :: binary(), Stack :: binary()}.
management_listener_bind_stack() ->
    case persistent_term:get(?H3_GATEWAY_LISTEN_PT, undefined) of
        {Bind, Stack} when is_binary(Bind), is_binary(Stack) ->
            {Bind, Stack};
        undefined ->
            management_listener_bind_stack_default()
    end.

management_listener_bind_stack_default() ->
    case os:type() of
        {unix, linux} ->
            %% Intended bind: UDP/IPv6 :: with IPV6_V6ONLY=0 (may fall back to IPv4-only at runtime).
            {<<"::">>, <<"dual_stack">>};
        {unix, _} ->
            case non_linux_h3_ipv6_enabled() of
                true -> {<<"0.0.0.0 and ::">>, <<"dual_stack">>};
                false -> {<<"0.0.0.0">>, <<"ipv4">>}
            end;
        win32 ->
            case non_linux_h3_ipv6_enabled() of
                true -> {<<"0.0.0.0 and ::">>, <<"dual_stack">>};
                false -> {<<"0.0.0.0">>, <<"ipv4">>}
            end;
        _ ->
            {<<"0.0.0.0">>, <<"ipv4">>}
    end.

note_h3_gateway_udp_listen(?SERVER, Bind, Stack) when is_binary(Bind), is_binary(Stack) ->
    persistent_term:put(?H3_GATEWAY_LISTEN_PT, {Bind, Stack}),
    ok;
note_h3_gateway_udp_listen(_, _, _) ->
    ok.

start_prefer_ipv6_server(Port, BaseOpts) ->
    start_prefer_ipv6_server(?SERVER, Port, BaseOpts).

start_prefer_ipv6_server(ServerName, Port, BaseOpts) ->
    ListenerBackend = maps:get(listener_backend, BaseOpts, gen_udp),
    case maps:get(h3_quic_ipv4_only, BaseOpts, false) of
        true ->
            V4Opts = linux_h3_quic_v4_server_opts(BaseOpts, ListenerBackend),
            lager:debug("H3 QUIC quic_opts (h3_quic_ipv4_only): ~p", [maps:get(quic_opts, V4Opts, #{})]),
            start_h3_quic_ipv4_only_stack(ServerName, Port, V4Opts);
        false ->
            %% Linux: split UDP (IPv4 + [::] with IPV6_V6ONLY=1 on the companion).
            case os:type() of
                {unix, linux} ->
                    V4Opts = linux_h3_quic_v4_server_opts(BaseOpts, ListenerBackend),
                    lager:debug("H3 QUIC quic_opts (linux split v4+ipv6): ~p", [maps:get(quic_opts, V4Opts, #{})]),
                    start_non_linux_dual_stack(ServerName, Port, V4Opts);
                _ ->
                    lager:debug("H3 QUIC: starting dual listeners (IPv4 + IPv6) on non-linux: ~p", [
                        maps:get(quic_opts, BaseOpts, #{})
                    ]),
                    case non_linux_h3_ipv6_enabled() of
                        true ->
                            start_non_linux_dual_stack(ServerName, Port, BaseOpts);
                        false ->
                            lager:info("H3 QUIC non-linux IPv6 companion listener disabled (set {h3_ipv6_non_linux,true} in sys.config to enable)."),
                            case pertisk_h3_transport:start_server(ServerName, Port, BaseOpts) of
                                {ok, _} = Ok ->
                                    note_h3_gateway_udp_listen(ServerName, <<"0.0.0.0">>, <<"ipv4">>),
                                    Ok;
                                {error, Reason} -> {error, {failed_quic_udp_listener, Reason}}
                            end
                    end
            end
    end.

%% @private Single UDP listener on IPv4 (inet) only; see {@code h3_quic_ipv4_only} in proxy.json.
start_h3_quic_ipv4_only_stack(ServerName, Port, V4Opts) ->
    case pertisk_h3_transport:start_server(ServerName, Port, V4Opts) of
        {ok, _} = Ok ->
            note_h3_gateway_udp_listen(ServerName, <<"0.0.0.0">>, <<"ipv4">>),
            Ok;
        {error, Reason} ->
            {error, {failed_quic_udp_listener, Reason}}
    end.

linux_h3_quic_v4_server_opts(BaseOpts, ListenerBackend) ->
    BaseOpts#{
        quic_opts => maps:merge(
            maps:get(quic_opts, BaseOpts, #{}),
            #{
                socket_backend => ListenerBackend,
                backend => ListenerBackend,
                server_send_batching => false,
                reuseport => false,
                pool_size => 0,
                extra_socket_opts => [],
                %% Chromium paths sometimes lose PMTUD probes where curl/Firefox succeed; disable DPLPMTUD here.
                pmtu_enabled => false
            }
        )
    }.

start_non_linux_dual_stack(ServerName, Port, V4Opts) ->
    case pertisk_h3_transport:start_server(ServerName, Port, V4Opts) of
        {ok, Pid} ->
            V6Name = v6_server_name(ServerName),
            V6Opts = non_linux_v6_opts(V4Opts),
            case pertisk_h3_transport:start_server(V6Name, Port, V6Opts) of
                {ok, _V6Pid} ->
                    note_h3_gateway_udp_listen(ServerName, <<"0.0.0.0 and ::">>, <<"dual_stack">>),
                    {ok, Pid};
                {error, Reason} ->
                    lager:warning("H3 QUIC IPv6 listener failed on udp/:~w (~p). Continuing with IPv4 only.", [Port, Reason]),
                    note_h3_gateway_udp_listen(ServerName, <<"0.0.0.0">>, <<"ipv4">>),
                    {ok, Pid}
            end;
        {error, Reason} ->
            {error, {failed_quic_udp_listener, Reason}}
    end.

v6_server_name(?SERVER) ->
    ?SERVER_V6;
v6_server_name(?PROBE_SERVER) ->
    ?PROBE_SERVER_V6.

non_linux_v6_opts(BaseOpts) ->
    %% Do not force `socket_backend => socket' here: on Darwin/BSD the OTP `socket'
    %% UDP listener often fails init with einval for the [::]:P companion, while
    %% `gen_udp' matches the successful IPv4 listener (quic_listener:init_genudp_backend).
    Q0 = maps:get(quic_opts, BaseOpts, #{}),
    Q1 = maps:without([socket_backend, backend], Q0),
    BaseOpts#{
        quic_opts => maps:merge(Q1, #{
            socket_backend => gen_udp,
            reuseport => false,
            pool_size => 0,
            extra_socket_opts => [inet6, {ipv6_v6only, true}]
        })
    }.

non_linux_h3_ipv6_enabled() ->
    case application:get_env(pertisk_eproxy, h3_ipv6_non_linux) of
        {ok, true} -> true;
        _ -> false
    end.

load_cert_and_key(Config) ->
    CertPath = maps:get(tls_cert_file, Config, "priv/tls/listener.pem"),
    KeyPath = maps:get(tls_key_file, Config, "priv/tls/listener.key"),
    {ok, CertPem} = file:read_file(CertPath),
    {ok, KeyPem} = file:read_file(KeyPath),
    [CertEntry | _] = public_key:pem_decode(CertPem),
    [KeyEntry | _] = public_key:pem_decode(KeyPem),
    {element(2, CertEntry), public_key:pem_entry_decode(KeyEntry)}.
