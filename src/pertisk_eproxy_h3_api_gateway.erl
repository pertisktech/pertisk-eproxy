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
    Port = case maps:get(quic_port, Config, undefined) of
        P when is_integer(P), P > 0 -> P;
        _ -> maps:get(https_port, Config, 443)
    end,
    case load_cert_and_key(Config) of
        {ok, {CertDer, KeyTerm}} ->
            do_start_gateway(Port, CertDer, KeyTerm);
        {error, Reason} ->
            {error, Reason}
    end.

do_start_gateway(Port, CertDer, KeyTerm) ->
    BaseOpts = #{
        cert => CertDer,
        key => KeyTerm,
        settings => #{
            %% Force static QPACK to avoid dynamic table/base calculation
            %% interoperability failures seen from external clients.
            qpack_max_table_capacity => 0,
            qpack_blocked_streams => 0
        },
        handler => ?MODULE
    },
    start_prefer_ipv6_server(Port, BaseOpts).

stop() ->
    catch quic_h3:stop_server(?SERVER),
    ok.

start_probe(Config) ->
    _ = ensure_quic_started(),
    _ = ensure_gun_started(),
    BasePort = case maps:get(quic_port, Config, undefined) of
        P when is_integer(P), P > 0 -> P;
        _ -> maps:get(https_port, Config, 443)
    end,
    ProbePort = maps:get(h3_probe_port, Config, BasePort + 1),
    case load_cert_and_key(Config) of
        {ok, {CertDer, KeyTerm}} ->
            do_start_probe(ProbePort, CertDer, KeyTerm);
        {error, Reason} ->
            {error, Reason}
    end.

do_start_probe(ProbePort, CertDer, KeyTerm) ->
    ProbeOpts = #{
        cert => CertDer,
        key => KeyTerm,
        handler => pertisk_eproxy_h3_probe_handler
    },
    start_prefer_ipv6_server(?PROBE_SERVER, ProbePort, ProbeOpts).

stop_probe() ->
    catch quic_h3:stop_server(?PROBE_SERVER),
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
                        case proxy_via_gun(
                            Method, LogHost, UpPath, Qs, UpstreamAddr, Headers, Body, ClientIp
                        ) of
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
                                ok = quic_h3:send_response(H3Conn, StreamId, Status, RespHeaders),
                                _ = quic_h3:send_data(H3Conn, StreamId, RespBin, true),
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
        _ -> read_request_body_post(Conn, StreamId, Headers, PathOnly)
    end.

read_request_body_post(Conn, StreamId, Headers, PathOnly) ->
    TimeoutMs = h3_body_collect_timeout_ms(Headers, PathOnly),
    case quic_h3:set_stream_handler(Conn, StreamId, self()) of
        {ok, Buffered} ->
            collect_body(Conn, StreamId, chunks_to_binary(Buffered), TimeoutMs);
        ok ->
            collect_body(Conn, StreamId, <<>>, TimeoutMs);
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

collect_body(_Conn, _StreamId, Acc, TimeoutMs) when TimeoutMs =< 0 ->
    Acc;
collect_body(Conn, StreamId, Acc, TimeoutMs) ->
    T0 = erlang:monotonic_time(millisecond),
    receive
        {quic_h3, Conn, {data, StreamId, Data, true}} ->
            <<Acc/binary, Data/binary>>;
        {quic_h3, Conn, {data, StreamId, Data, false}} ->
            Elapsed = erlang:monotonic_time(millisecond) - T0,
            Remaining = TimeoutMs - Elapsed,
            collect_body(Conn, StreamId, <<Acc/binary, Data/binary>>, Remaining)
    after TimeoutMs ->
        Acc
    end.

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
    case os:type() of
        {unix, linux} ->
            %% UDP/IPv6 :: with IPV6_V6ONLY=0 → accept IPv4 and IPv6 clients.
            {<<"::">>, <<"dual_stack">>};
        {unix, _} ->
            {<<"0.0.0.0">>, <<"ipv4">>};
        win32 ->
            {<<"0.0.0.0">>, <<"ipv4">>};
        _ ->
            {<<"0.0.0.0">>, <<"ipv4">>}
    end.

start_prefer_ipv6_server(Port, BaseOpts) ->
    start_prefer_ipv6_server(?SERVER, Port, BaseOpts).

start_prefer_ipv6_server(ServerName, Port, BaseOpts) ->
    %% On Linux: bind UDP over IPv6 (::) with IPV6_V6ONLY=0 so IPv4 clients work.
    %% On macOS/BSD/Windows: quic_socket falls back to gen_udp, whose option list
    %% always includes `inet` then appends extra_socket_opts; adding `inet6`
    %% yields inet+inet6 together and gen_udp:open returns einval.
    {ServerOpts, LogLabel} =
        case os:type() of
            {unix, linux} ->
                V6Opts = BaseOpts#{
                    quic_opts => maps:merge(
                        maps:get(quic_opts, BaseOpts, #{}),
                        #{
                            socket_backend => socket,
                            backend => socket,
                            reuseport => false,
                            pool_size => 0,
                            extra_socket_opts => [inet6, {ipv6_v6only, false}]
                        }
                    )
                },
                {V6Opts, "H3 QUIC quic_opts (linux dual-stack): ~p"};
            _ ->
                {BaseOpts, "H3 QUIC: default listener opts (non-linux, no inet6 extra_socket_opts)"}
        end,
    lager:debug(LogLabel, [maps:get(quic_opts, ServerOpts, #{})]),
    case quic_h3:start_server(ServerName, Port, ServerOpts) of
        {ok, _Pid} = Ok ->
            Ok;
        {error, V6Reason} ->
            {error, {failed_quic_udp_listener, V6Reason}}
    end.

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
        [CertEntry | _] = public_key:pem_decode(CertPem),
        [KeyEntry | _] = public_key:pem_decode(KeyPem),
        {ok, {element(2, CertEntry), public_key:pem_entry_decode(KeyEntry)}}
    catch
        _:_ ->
            {error, {invalid_listener_pem, CertPath, KeyPath}}
    end.
