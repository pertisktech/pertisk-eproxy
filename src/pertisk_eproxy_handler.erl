%% @doc HTTP reverse proxy handler for pertisk_eproxy.
%%
%% This cowboy handler intercepts all requests on the proxy listeners,
%% performs routing, picks an upstream, and forwards the request via gun.
%%
%% Features:
%%   - Path-based routing (exact / prefix) via pertisk_eproxy_router
%%   - Load balancing via pertisk_eproxy_backend (round-robin / least-conn / ip-hash)
%%   - WebSocket upgrade detection → delegates to pertisk_eproxy_ws_handler
%%   - Forwards X-Forwarded-For, X-Forwarded-Proto, X-Forwarded-Proto-Version
%%   - Preserves original Host header to upstream
%%   - Streaming response body (chunked friendly)
%%   - Per-request timeout (default 60 s)

-module(pertisk_eproxy_handler).
-behaviour(cowboy_handler).

-export([
    init/2,
    parse_upstream/1,
    site_advertise_http3/1,
    websocket_init/1,
    websocket_handle/2,
    websocket_info/2,
    terminate/3
]).

-define(REQUEST_TIMEOUT, 60000).
-define(CONNECT_TIMEOUT, 10000).

%% @doc Prometheus `proto` label for TCP/TLS Cowboy requests (HTTP/3 uses the QUIC gateway).
cowboy_req_proto_metric(Req) ->
    case cowboy_req:version(Req) of
        'HTTP/3' ->
            <<"h3">>;
        'HTTP/2' ->
            <<"h2">>;
        'HTTP/1.1' ->
            http1_proto_bin(cowboy_req:scheme(Req));
        'HTTP/1.0' ->
            http1_proto_bin(cowboy_req:scheme(Req));
        _ ->
            <<"http1">>
    end.

http1_proto_bin(https) -> <<"tls_h1">>;
http1_proto_bin(<<"https">>) -> <<"tls_h1">>;
http1_proto_bin(_) -> <<"http1">>.

init(Req, State) ->
    Method = cowboy_req:method(Req),
    Host   = cowboy_req:host(Req),
    Path   = cowboy_req:path(Req),
    Qs     = cowboy_req:qs(Req),

    %% Check for WebSocket upgrade
    case is_websocket_upgrade(Req) of
        true ->
            pertisk_eproxy_ws_handler:init(Req, State);
        false ->
            handle_http(Req, State, Method, Host, Path, Qs)
    end.

handle_http(Req, State, Method, Host, Path, Qs) ->
    T0 = erlang:monotonic_time(millisecond),
    Vsn = cowboy_req:version(Req),
    Proto = request_proto_metric(Req),
    TrackingId = request_tracking_id(Req),
    case pertisk_eproxy_router:route(Host, Path) of
        {error, no_route} ->
            pertisk_eproxy_metrics:inc_request(Host, <<"404">>, Proto),
            H404 = maybe_add_alt_svc(
                Req,
                Host,
                with_tracking_id_header(TrackingId, #{<<"content-type">> => <<"text/plain">>})
            ),
            Body404 = <<"No route found for host: ", Host/binary>>,
            {H404Out, Body404Out} =
                pertisk_eproxy_compression:maybe_compress_cowboy(404, Req, H404, Body404),
            Req2 = cowboy_req:reply(404, H404Out, Body404Out, Req),
            log_access(Host, Method, Path, 404, T0, Vsn, <<>>),
            {ok, Req2, State};
        {ok, #{upstream_path := UpstreamPath, backend := BackendName}} ->
            ClientIp = client_ip(Req),
            case pertisk_eproxy_backend:pick_upstream(BackendName, ClientIp) of
                {error, no_healthy_upstream} ->
                    case maybe_proxy_via_local_management(
                        Req,
                        Method,
                        Host,
                        UpstreamPath,
                        Qs,
                        ClientIp,
                        TrackingId
                    ) of
                        {ok, StatusCode, Req2} ->
                            StatusBin = integer_to_binary(StatusCode),
                            pertisk_eproxy_metrics:inc_request(Host, StatusBin, Proto),
                            log_access(
                                Host,
                                Method,
                                Path,
                                StatusCode,
                                T0,
                                Vsn,
                                pertisk_eproxy_config:management_loopback_upstream_bin()
                            ),
                            {ok, Req2, State};
                        _ ->
                            pertisk_eproxy_metrics:inc_request(Host, <<"502">>, Proto),
                            H502 = maybe_add_alt_svc(
                                Req,
                                Host,
                                with_tracking_id_header(TrackingId, #{<<"content-type">> => <<"text/plain">>})
                            ),
                            Body502 = <<"Bad Gateway: no healthy upstream">>,
                            {H502Out, Body502Out} =
                                pertisk_eproxy_compression:maybe_compress_cowboy(502, Req, H502, Body502),
                            Req2 = cowboy_req:reply(502, H502Out, Body502Out, Req),
                            log_access(Host, Method, Path, 502, T0, Vsn, <<>>),
                            {ok, Req2, State}
                    end;
                {ok, UpstreamAddr} ->
                    Result = proxy_request(Req, Method, Host, UpstreamPath, Qs,
                                           UpstreamAddr, ClientIp, TrackingId),
                    case Result of
                        {ok, StatusCode, Req2} ->
                            StatusBin = integer_to_binary(StatusCode),
                            pertisk_eproxy_metrics:inc_request(Host, StatusBin, Proto),
                            pertisk_eproxy_backend:done_upstream(BackendName, UpstreamAddr, ok),
                            log_access(Host, Method, Path, StatusCode, T0, Vsn, UpstreamAddr),
                            {ok, Req2, State};
                        {error, Reason} ->
                            pertisk_eproxy_backend:done_upstream(BackendName, UpstreamAddr, error),
                            case maybe_proxy_via_local_management(
                                Req,
                                Method,
                                Host,
                                UpstreamPath,
                                Qs,
                                ClientIp,
                                TrackingId
                            ) of
                                {ok, StatusCode, Req2} ->
                                    StatusBin = integer_to_binary(StatusCode),
                                    pertisk_eproxy_metrics:inc_request(Host, StatusBin, Proto),
                                    log_access(
                                        Host,
                                        Method,
                                        Path,
                                        StatusCode,
                                        T0,
                                        Vsn,
                                        pertisk_eproxy_config:management_loopback_upstream_bin()
                                    ),
                                    {ok, Req2, State};
                                _ ->
                                    pertisk_eproxy_metrics:inc_request(Host, <<"502">>, Proto),
                                    lager:warning("Proxy error ~p for ~s~s -> ~s",
                                                  [Reason, Host, Path, UpstreamAddr]),
                                    H502 = maybe_add_alt_svc(
                                        Req,
                                        Host,
                                        with_tracking_id_header(TrackingId, #{<<"content-type">> => <<"text/plain">>})
                                    ),
                                    Body502 = <<"Bad Gateway">>,
                                    {H502Out, Body502Out} =
                                        pertisk_eproxy_compression:maybe_compress_cowboy(502, Req, H502, Body502),
                                    Req2 = cowboy_req:reply(502, H502Out, Body502Out, Req),
                                    log_access(Host, Method, Path, 502, T0, Vsn, UpstreamAddr),
                                    {ok, Req2, State}
                            end
                    end
            end
    end.

maybe_proxy_via_local_management(Req, Method, Host, UpstreamPath, Qs, ClientIp, TrackingId) ->
    case should_try_local_management_fallback(Host, UpstreamPath) of
        false ->
            no_fallback;
        true ->
            Mgmt = pertisk_eproxy_config:management_loopback_upstream_bin(),
            proxy_request(Req, Method, Host, UpstreamPath, Qs, Mgmt, ClientIp, TrackingId)
    end.

should_try_local_management_fallback(Host, _Path) ->
    LowerHost = string:lowercase(Host),
    binary:match(LowerHost, <<"admin.">>) =:= {0, byte_size(<<"admin.">>)}.

log_access(Host, Method, Path, Status, T0, Vsn, Upstream) ->
    Dt = max(0, erlang:monotonic_time(millisecond) - T0),
    catch pertisk_eproxy_access_log:log_proxy(Host, Method, Path, Status, Dt, Vsn, Upstream).

%% -------------------------------------------------------------------------
%% Core proxy logic using gun
%% -------------------------------------------------------------------------

proxy_request(Req, Method, Host, UpstreamPath, Qs, UpstreamAddr, ClientIp, TrackingId) ->
    {UpHost, UpPort, Transport} = parse_upstream(UpstreamAddr),
    FullPath = case Qs of
        <<>> -> UpstreamPath;
        _    -> <<UpstreamPath/binary, "?", Qs/binary>>
    end,

    ReqKind = detect_request_kind(Req),
    GunOpts = upstream_gun_opts(UpHost, Transport, ReqKind),
    {ok, Body} = read_body(Req),

    case pertisk_eproxy_upstream_pool:checkout(UpHost, UpPort, Transport, ReqKind, GunOpts) of
        {error, Reason} ->
            {error, Reason};
        {ok, ConnPid} ->
            do_proxy(
                Req,
                ConnPid,
                Method,
                Host,
                FullPath,
                ClientIp,
                TrackingId,
                Body,
                UpHost,
                UpPort,
                Transport,
                ReqKind,
                GunOpts,
                0
            )
    end.

upstream_gun_opts(UpHost, tls, ReqKind) ->
    #{
        transport => tls,
        protocols => gun_protocols_for_request(ReqKind),
        connect_timeout => ?CONNECT_TIMEOUT,
        tls_opts => upstream_tls_opts(UpHost)
    };
upstream_gun_opts(_UpHost, Transport, ReqKind) ->
    #{
        transport => Transport,
        protocols => gun_protocols_for_request(ReqKind),
        connect_timeout => ?CONNECT_TIMEOUT
    }.

upstream_tls_opts(UpHost) ->
    %% Upstreams are often internal services with private/self-signed certs.
    %% Keep reverse-proxy behavior permissive unless strict verification is introduced in config.
    [{verify, verify_none} | maybe_sni_opt(UpHost)].

maybe_sni_opt(UpHost) when is_list(UpHost) ->
    case inet:parse_address(UpHost) of
        {ok, _Ip} -> [{server_name_indication, disable}];
        _ -> [{server_name_indication, UpHost}]
    end;
maybe_sni_opt(UpHost) when is_binary(UpHost) ->
    maybe_sni_opt(binary_to_list(UpHost));
maybe_sni_opt(_) ->
    [{server_name_indication, disable}].

do_proxy(
    Req,
    ConnPid,
    Method,
    Host,
    FullPath,
    ClientIp,
    TrackingId,
    Body,
    UpHost,
    UpPort,
    Transport,
    ReqKind,
    GunOpts,
    RetryCount
) ->
    HeadersMap = forward_headers(Req, Host, ClientIp, FullPath, TrackingId),
    Headers = maps:to_list(HeadersMap),
    ReqBodyBytes = byte_size(Body),

    Result =
        try
            GunMethod = method_to_gun(Method),
            StreamRef = gun:request(ConnPid, GunMethod, FullPath, Headers, Body),
            case ReqKind of
                grpc ->
                    do_proxy_grpc_streaming(
                        Req,
                        ConnPid,
                        StreamRef,
                        Host,
                        TrackingId,
                        ReqBodyBytes
                    );
                _ ->
                    case gun:await(ConnPid, StreamRef, ?REQUEST_TIMEOUT) of
                        {response, nofin, Status, RespHeaders} ->
                            case gun:await_body(ConnPid, StreamRef, ?REQUEST_TIMEOUT) of
                                {ok, RespBody} ->
                                    RespBin = iolist_to_binary(RespBody),
                                    ok = pertisk_eproxy_metrics:record_proxy_bytes(Host, ReqBodyBytes, byte_size(RespBin)),
                                    {Req1, RawHeaders} = response_headers_to_req(Req, RespHeaders),
                                    CowboyHeaders = maybe_add_alt_svc(Req1, Host, RawHeaders),
                                    CowboyHeaders2 = with_tracking_id_header(TrackingId, CowboyHeaders),
                                    {OutHeaders, OutBody} =
                                        pertisk_eproxy_compression:maybe_compress_cowboy(Status, Req1, CowboyHeaders2, RespBin),
                                    Req2 = cowboy_req:reply(Status, OutHeaders, OutBody, Req1),
                                    {ok, Status, Req2};
                                {ok, RespBody, _Trailers} ->
                                    RespBin = iolist_to_binary(RespBody),
                                    ok = pertisk_eproxy_metrics:record_proxy_bytes(Host, ReqBodyBytes, byte_size(RespBin)),
                                    {Req1, RawHeaders} = response_headers_to_req(Req, RespHeaders),
                                    CowboyHeaders = maybe_add_alt_svc(Req1, Host, RawHeaders),
                                    CowboyHeaders2 = with_tracking_id_header(TrackingId, CowboyHeaders),
                                    {OutHeaders, OutBody} =
                                        pertisk_eproxy_compression:maybe_compress_cowboy(Status, Req1, CowboyHeaders2, RespBin),
                                    Req2 = cowboy_req:reply(Status, OutHeaders, OutBody, Req1),
                                    {ok, Status, Req2};
                                {error, Reason} ->
                                    {error, Reason};
                                Other ->
                                    {error, {await_body_unexpected, Other}}
                            end;
                        {response, fin, Status, RespHeaders} ->
                            ok = pertisk_eproxy_metrics:record_proxy_bytes(Host, ReqBodyBytes, 0),
                            {Req1, RawHeaders} = response_headers_to_req(Req, RespHeaders),
                            CowboyHeaders = maybe_add_alt_svc(Req1, Host, RawHeaders),
                            Req2 = cowboy_req:reply(Status, with_tracking_id_header(TrackingId, CowboyHeaders), <<>>, Req1),
                            {ok, Status, Req2};
                        {error, Reason} ->
                            {error, Reason}
                    end
            end
        catch
            Class:CaughtReason ->
                {error, {Class, CaughtReason}}
        end,
    case Result of
        {error, ProxyReason} ->
            maybe_invalidate_connection(ConnPid, ProxyReason),
            case ReqKind =/= grpc andalso RetryCount =:= 0 andalso retryable_upstream_error(ProxyReason) of
                true ->
                    case pertisk_eproxy_upstream_pool:checkout(
                        UpHost, UpPort, Transport, ReqKind, GunOpts
                    ) of
                        {ok, ConnPid2} ->
                            do_proxy(
                                Req,
                                ConnPid2,
                                Method,
                                Host,
                                FullPath,
                                ClientIp,
                                TrackingId,
                                Body,
                                UpHost,
                                UpPort,
                                Transport,
                                ReqKind,
                                GunOpts,
                                1
                            );
                        {error, _} = RetryErr ->
                            RetryErr
                    end;
                false ->
                    {error, ProxyReason}
            end;
        _ ->
            Result
    end.

do_proxy_grpc_streaming(Req, ConnPid, StreamRef, Host, TrackingId, ReqBodyBytes) ->
    %% gRPC watch/stream calls may stay idle before the first message; do not
    %% enforce the generic HTTP request timeout on initial response await.
    case gun:await(ConnPid, StreamRef, infinity) of
        {response, nofin, Status, RespHeaders} ->
            {Req1, RawHeaders} = response_headers_to_req(Req, RespHeaders),
            CowboyHeaders = maybe_add_alt_svc(Req1, Host, RawHeaders),
            StreamReq = cowboy_req:stream_reply(
                Status,
                with_tracking_id_header(TrackingId, CowboyHeaders),
                Req1
            ),
            proxy_grpc_stream_loop(ConnPid, StreamRef, StreamReq, Host, ReqBodyBytes, 0, Status);
        {response, fin, Status, RespHeaders} ->
            {Req1, RawHeaders} = response_headers_to_req(Req, RespHeaders),
            CowboyHeaders = maybe_add_alt_svc(Req1, Host, RawHeaders),
            Req2 = cowboy_req:reply(Status, with_tracking_id_header(TrackingId, CowboyHeaders), <<>>, Req1),
            ok = pertisk_eproxy_metrics:record_proxy_bytes(Host, ReqBodyBytes, 0),
            {ok, Status, Req2};
        {error, Reason} ->
            {error, Reason};
        Other ->
            {error, {await_response_unexpected, Other}}
    end.

proxy_grpc_stream_loop(ConnPid, StreamRef, Req, Host, ReqBodyBytes, RespBytes, Status) ->
    case gun:await(ConnPid, StreamRef, infinity) of
        {data, nofin, Chunk} ->
            ChunkBin = iolist_to_binary(Chunk),
            ok = cowboy_req:stream_body(ChunkBin, nofin, Req),
            proxy_grpc_stream_loop(
                ConnPid,
                StreamRef,
                Req,
                Host,
                ReqBodyBytes,
                RespBytes + byte_size(ChunkBin),
                Status
            );
        {data, fin, Chunk} ->
            ChunkBin = iolist_to_binary(Chunk),
            ok = cowboy_req:stream_body(ChunkBin, fin, Req),
            FinalRespBytes = RespBytes + byte_size(ChunkBin),
            ok = pertisk_eproxy_metrics:record_proxy_bytes(Host, ReqBodyBytes, FinalRespBytes),
            {ok, Status, Req};
        {trailers, Trailers} ->
            ok = maybe_stream_trailers(Req, Trailers),
            ok = pertisk_eproxy_metrics:record_proxy_bytes(Host, ReqBodyBytes, RespBytes),
            {ok, Status, Req};
        {error, Reason} ->
            {error, Reason};
        Other ->
            {error, {await_stream_unexpected, Other}}
    end.

maybe_stream_trailers(Req, Trailers) when is_list(Trailers) ->
    TrailerMap = maps:from_list(Trailers),
    case erlang:function_exported(cowboy_req, stream_trailers, 2) of
        true ->
            _ = catch apply(cowboy_req, stream_trailers, [TrailerMap, Req]),
            ok;
        false ->
            ok
    end;
maybe_stream_trailers(Req, Trailers) when is_map(Trailers) ->
    case erlang:function_exported(cowboy_req, stream_trailers, 2) of
        true ->
            _ = catch apply(cowboy_req, stream_trailers, [Trailers, Req]),
            ok;
        false ->
            ok
    end;
maybe_stream_trailers(_Req, _Trailers) ->
    ok.

retryable_upstream_error({down, normal}) -> true;
retryable_upstream_error({down, shutdown}) -> true;
retryable_upstream_error({stream_error, {closing, owner_down}}) -> true;
retryable_upstream_error(_) -> false.

maybe_invalidate_connection(ConnPid, Reason) ->
    case is_connection_fatal_error(Reason) of
        true ->
            pertisk_eproxy_upstream_pool:invalidate(ConnPid);
        false ->
            ok
    end.

is_connection_fatal_error({stream_error, {closing, owner_down}}) -> false;
is_connection_fatal_error(_) -> true.

%% -------------------------------------------------------------------------
%% Header helpers
%% -------------------------------------------------------------------------

forward_headers(Req, OrigHost, ClientIp, FullPath, TrackingId) ->
    InHeaders = cowboy_req:headers(Req),
    Proto     = case cowboy_req:port(Req) of
        443 -> <<"https">>;
        _   -> <<"http">>
    end,
    ProtoVsn  = version_to_bin(cowboy_req:version(Req)),

    %% Start from original headers, drop hop-by-hop
    Filtered = maps:without([<<"connection">>, <<"keep-alive">>, <<"te">>,
                              <<"trailers">>, <<"transfer-encoding">>,
                              <<"upgrade">>], InHeaders),

    %% Preserve original Host
    Base0 = Filtered#{
        <<"host">>                     => OrigHost,
        <<"x-forwarded-proto">>        => Proto,
        <<"x-forwarded-proto-version">> => ProtoVsn,
        <<"x-request-id">> => TrackingId
    },

    %% Proxmox console ticket endpoints may validate source identity across
    %% termproxy/vncproxy and vncwebsocket calls; avoid XFF drift between H3 and TCP.
    case skip_forwarded_for(OrigHost, FullPath) of
        true ->
            maps:remove(<<"x-forwarded-for">>, Base0);
        false ->
            XFF = case maps:find(<<"x-forwarded-for">>, Base0) of
                {ok, Existing} -> <<Existing/binary, ", ", ClientIp/binary>>;
                error          -> ClientIp
            end,
            Base0#{<<"x-forwarded-for">> => XFF}
    end.

skip_forwarded_for(Host, Path) when is_binary(Host), is_binary(Path) ->
    HostL = string:lowercase(Host),
    IsProxmoxHost = binary:match(HostL, <<"proxmox">>) =/= nomatch,
    IsConsolePath =
        binary:match(Path, <<"/termproxy">>) =/= nomatch orelse
        binary:match(Path, <<"/vncproxy">>) =/= nomatch orelse
        binary:match(Path, <<"/vncwebsocket">>) =/= nomatch,
    IsProxmoxHost andalso IsConsolePath;
skip_forwarded_for(_, _) ->
    false.

version_to_bin('HTTP/1.0') -> <<"HTTP/1.0">>;
version_to_bin('HTTP/1.1') -> <<"HTTP/1.1">>;
version_to_bin('HTTP/2')   -> <<"HTTP/2">>;
version_to_bin(_)          -> <<"HTTP/1.1">>.

response_headers_to_req(Req, List) when is_list(List) ->
    {Req1, Filtered} = lists:foldl(
        fun({K, V}, {ReqAcc, HeadersAcc}) ->
            case string:lowercase(K) of
                <<"set-cookie">> ->
                    case cow_cookie:parse_set_cookie(iolist_to_binary(V)) of
                        {ok, Name, Value, Attrs} ->
                            Opts = cookie_attrs_to_opts(Attrs),
                            {cowboy_req:set_resp_cookie(Name, Value, ReqAcc, Opts), HeadersAcc};
                        ignore ->
                            {ReqAcc, HeadersAcc}
                    end;
                LowerK ->
                    {ReqAcc, [{LowerK, V} | HeadersAcc]}
            end
        end,
        {Req, []},
        List
    ),
    {Req1, maps:from_list(Filtered)}.

%% cow_cookie:parse_set_cookie/1 returns `max_age` as an absolute calendar
%% datetime, and may include `expires`. cowboy_req:set_resp_cookie/4 expects
%% `max_age` as a non-negative integer (seconds) and does not accept `expires`.
%% Translate so we don't crash with {badarg, {max_age, {{Y,M,D},{H,M,S}}}}.
cookie_attrs_to_opts(Attrs) when is_map(Attrs) ->
    Attrs1 = maps:remove(expires, Attrs),
    case maps:find(max_age, Attrs1) of
        {ok, {{_, _, _}, {_, _, _}} = DT} ->
            try
                NowSecs = calendar:datetime_to_gregorian_seconds(calendar:universal_time()),
                ExpSecs = calendar:datetime_to_gregorian_seconds(DT),
                Diff = ExpSecs - NowSecs,
                MaxAge = if Diff < 0 -> 0; true -> Diff end,
                Attrs1#{max_age => MaxAge}
            catch
                _:_ ->
                    maps:remove(max_age, Attrs1)
            end;
        {ok, MA} when is_integer(MA), MA >= 0 ->
            Attrs1;
        {ok, _} ->
            maps:remove(max_age, Attrs1);
        error ->
            Attrs1
    end;
cookie_attrs_to_opts(_) ->
    #{}.

%% -------------------------------------------------------------------------
%% Utilities
%% -------------------------------------------------------------------------

is_websocket_upgrade(Req) ->
    Upgrade = cowboy_req:header(<<"upgrade">>, Req, <<>>),
    case string:lowercase(Upgrade) =:= <<"websocket">> of
        true ->
            true;
        false ->
            %% Some proxies/clients (e.g. HTTP/2 extended CONNECT paths)
            %% may not carry classic Upgrade/Connection headers.
            has_ws_handshake_headers(Req)
    end.

has_ws_handshake_headers(Req) ->
    case cowboy_req:header(<<"sec-websocket-key">>, Req, undefined) of
        undefined ->
            case cowboy_req:header(<<"sec-websocket-version">>, Req, undefined) of
                undefined -> false;
                _ -> true
            end;
        _ ->
            true
    end.

request_proto_metric(Req) ->
    case detect_request_kind(Req) of
        grpc -> <<"grpc">>;
        _ -> cowboy_req_proto_metric(Req)
    end.

detect_request_kind(Req) ->
    case is_websocket_upgrade(Req) of
        true -> websocket;
        false ->
            case is_grpc_request(Req) of
                true -> grpc;
                false -> http
            end
    end.

is_grpc_request(Req) ->
    Ct = cowboy_req:header(<<"content-type">>, Req, <<>>),
    CtLower = string:lowercase(Ct),
    case CtLower of
        <<"application/grpc", _/binary>> -> true;
        <<"application/grpc-web", _/binary>> -> true;
        <<"application/connect+", _/binary>> -> true;
        _ ->
            %% gRPC over HTTP/2 commonly carries TE: trailers. Browser grpc-web
            %% requests may omit TE but include grpc-metadata-* headers.
            Te = string:lowercase(cowboy_req:header(<<"te">>, Req, <<>>)),
            (Te =:= <<"trailers">>) orelse has_grpc_metadata_headers(Req)
    end.

has_grpc_metadata_headers(Req) ->
    Hdrs = cowboy_req:headers(Req),
    lists:any(
        fun(K) when is_binary(K) ->
            case K of
                <<"grpc-metadata-", _/binary>> -> true;
                <<"grpc-timeout">> -> true;
                <<"x-grpc-web">> -> true;
                _ -> false
            end;
           (_) ->
            false
        end,
        maps:keys(Hdrs)
    ).

gun_protocols_for_request(grpc) ->
    %% gRPC requires HTTP/2 transport semantics.
    [http2];
gun_protocols_for_request(_) ->
    [http].

client_ip(Req) ->
    case cowboy_req:header(<<"x-forwarded-for">>, Req) of
        undefined ->
            {PeerIp, _Port} = cowboy_req:peer(Req),
            list_to_binary(inet:ntoa(PeerIp));
        XFF ->
            %% Use leftmost IP (original client)
            hd(binary:split(XFF, [<<", ">>, <<",">>]))
    end.

read_body(Req) ->
    read_body(Req, <<>>).
read_body(Req, Acc) ->
    case cowboy_req:read_body(Req, #{length => 1048576, period => 5000}) of
        {ok,   Data, _Req2} -> {ok, <<Acc/binary, Data/binary>>};
        {more, Data,  Req2} -> read_body(Req2, <<Acc/binary, Data/binary>>)
    end.

parse_upstream(Addr) when is_binary(Addr) ->
    parse_upstream(binary_to_list(Addr));
parse_upstream(Addr) ->
    Addr1 = string:trim(Addr),
    Addr2 = string:trim(Addr1, trailing, "/"),
    case string:find(Addr2, "://") of
        nomatch ->
            {Host, Port} = split_host_port(Addr2, 80),
            {Host, Port, tcp};
        _ ->
            parse_upstream_uri(Addr2)
    end.

parse_upstream_uri(Addr) ->
    try uri_string:parse(Addr) of
        #{scheme := Scheme0} = Uri ->
            Scheme = string:lowercase(uri_text_to_list(Scheme0)),
            {Transport, DefaultPort} = scheme_to_transport(Scheme),
            Host = uri_text_to_list(maps:get(host, Uri, <<"localhost">>)),
            Port = maps:get(port, Uri, DefaultPort),
            {Host, Port, Transport};
        _ ->
            {Host, Port} = split_host_port(Addr, 80),
            {Host, Port, tcp}
    catch
        _:_ ->
            {Host, Port} = split_host_port(Addr, 80),
            {Host, Port, tcp}
    end.

scheme_to_transport("https") -> {tls, 443};
scheme_to_transport("wss") -> {tls, 443};
scheme_to_transport("grpcs") -> {tls, 443};
scheme_to_transport("http") -> {tcp, 80};
scheme_to_transport("ws") -> {tcp, 80};
scheme_to_transport("grpc") -> {tcp, 80};
scheme_to_transport(_) -> {tcp, 80}.

uri_text_to_list(V) when is_binary(V) -> binary_to_list(V);
uri_text_to_list(V) when is_list(V) -> V;
uri_text_to_list(V) -> lists:flatten(io_lib:format("~p", [V])).

split_host_port(Addr, DefaultPort) ->
    case parse_bracket_host_port(Addr, DefaultPort) of
        {ok, HostPort} ->
            HostPort;
        error ->
            case string:split(Addr, ":", trailing) of
                [Host, PortStr] ->
                    case safe_port(PortStr) of
                        {ok, Port} -> {Host, Port};
                        error -> {Addr, DefaultPort}
                    end;
                [Host] ->
                    {Host, DefaultPort}
            end
    end.

parse_bracket_host_port([$[ | Rest], DefaultPort) ->
    case string:split(Rest, "]", trailing) of
        [Host, ""] ->
            {ok, {Host, DefaultPort}};
        [Host, [$: | PortStr]] ->
            case safe_port(PortStr) of
                {ok, Port} -> {ok, {Host, Port}};
                error -> error
            end;
        _ ->
            error
    end;
parse_bracket_host_port(_, _) ->
    error.

safe_port(PortStr0) ->
    PortStr = string:trim(PortStr0, trailing, "/"),
    try
        {ok, list_to_integer(PortStr)}
    catch
        _:_ ->
            error
    end.

method_to_gun(<<"GET">>)     -> <<"GET">>;
method_to_gun(<<"POST">>)    -> <<"POST">>;
method_to_gun(<<"PUT">>)     -> <<"PUT">>;
method_to_gun(<<"PATCH">>)   -> <<"PATCH">>;
method_to_gun(<<"DELETE">>)  -> <<"DELETE">>;
method_to_gun(<<"HEAD">>)    -> <<"HEAD">>;
method_to_gun(<<"OPTIONS">>) -> <<"OPTIONS">>;
method_to_gun(M)             -> M.

maybe_add_alt_svc(Req, Host, Headers) ->
    pertisk_eproxy_alt_svc:merge_response_headers(
        Req, normalize_host(Host), pertisk_eproxy_response_headers:merge(Headers)
    ).

with_tracking_id_header(TrackingId, Headers) when is_map(Headers) ->
    Headers#{<<"x-request-id">> => TrackingId}.

request_tracking_id(Req) ->
    case cowboy_req:header(<<"x-request-id">>, Req, <<>>) of
        <<>> -> generate_tracking_id();
        Existing -> Existing
    end.

generate_tracking_id() ->
    hex_bin(crypto:strong_rand_bytes(16)).

hex_bin(Bin) when is_binary(Bin) ->
    iolist_to_binary([io_lib:format("~2.16.0b", [B]) || <<B:8>> <= Bin]).

%% Delegate websocket callbacks when this handler upgrades requests to websocket
%% (Cowboy invokes callbacks on the original route module).
websocket_init(State) ->
    pertisk_eproxy_ws_handler:websocket_init(State).

websocket_handle(Frame, State) ->
    pertisk_eproxy_ws_handler:websocket_handle(Frame, State).

websocket_info(Info, State) ->
    pertisk_eproxy_ws_handler:websocket_info(Info, State).

terminate(Reason, Req, State) ->
    pertisk_eproxy_ws_handler:terminate(Reason, Req, State).

site_advertise_http3(Host) ->
    Config = pertisk_eproxy_config:get_config(),
    Sites = maps:get(sites, Config, []),
    case find_site_for_host(Sites, normalize_host(Host)) of
        undefined -> false;
        Site -> maps:get(advertise_http3, Site, true) =/= false
    end.

find_site_for_host([], _Host) -> undefined;
find_site_for_host(Sites, Host) ->
    %% Try exact-host sites first so a wildcard like "*.example.com" cannot
    %% shadow a more specific "admin.example.com".
    {Exact, Wild} = lists:partition(
        fun(S) ->
            case maps:get(host, S, <<>>) of
                <<"*.", _/binary>> -> false;
                _ -> true
            end
        end, Sites),
    case find_site_first_match(Exact, Host) of
        undefined -> find_site_first_match(Wild, Host);
        Site -> Site
    end.

find_site_first_match([], _Host) -> undefined;
find_site_first_match([Site | Rest], Host) ->
    SiteHost = string:lowercase(maps:get(host, Site, <<>>)),
    case host_matches(Host, SiteHost) of
        true -> Site;
        false -> find_site_first_match(Rest, Host)
    end.

host_matches(Host, <<"*.", Suffix/binary>>) ->
    case binary:match(Host, <<".">>) of
        nomatch -> false;
        {Pos, _} ->
            HostSuffix = binary:part(Host, Pos + 1, byte_size(Host) - Pos - 1),
            HostSuffix =:= Suffix
    end;
host_matches(Host, SiteHost) ->
    Host =:= SiteHost.

normalize_host(H) when is_binary(H) ->
    case binary:split(H, <<":">>) of
        [Name, _] -> string:lowercase(Name);
        [Name] -> string:lowercase(Name)
    end;
normalize_host(H) when is_list(H) ->
    normalize_host(list_to_binary(H)).
