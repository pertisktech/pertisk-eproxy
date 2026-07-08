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
%%   - Per-request timeout (configurable; default 180 s)

-module(pertisk_eproxy_handler).
-behaviour(cowboy_handler).

-export([
    init/2,
    parse_upstream/1,
    site_advertise_http3/1,
    site_http3_enabled/1,
    is_sse_proxy_path/1,
    is_event_stream_accept/1,
    is_sse_proxy_request/2,
    gun_protocols_for_eventstream/1,
    eventstream_upstream_candidates/4,
    eventstream_initial_await_timeout_ms/1,
    eventstream_upstream_retryable/1,
    with_eventstream_upstream/5,
    should_sse_early_flush/3,
    headers_have_sse_auth/1,
    upstream_gun_opts_with_port/4,
    upstream_req_kind/2,
    upstream_req_kind/3,
    is_connect_service_path/1,
    site_backend_grpc_upstream/1,
    websocket_init/1,
    websocket_handle/2,
    websocket_info/2,
    terminate/3
]).

-define(DEFAULT_REQUEST_TIMEOUT_MS, 180000).
-define(DEFAULT_LOOPBACK_REQUEST_TIMEOUT_MS, 15000).
-define(DEFAULT_EVENT_STREAM_HEARTBEAT_MS, 15000).
-define(DEFAULT_SSE_INITIAL_HEADERS_MS, 5000).
-define(CONNECT_TIMEOUT, 10000).
-define(GRPC_HTTP2_KEEPALIVE_MS, 20000).
-define(GRPC_HTTP2_KEEPALIVE_TOLERANCE, 2).

%% @doc Prometheus 'proto' label for TCP/TLS Cowboy requests (HTTP/3 uses the QUIC gateway).
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
    ClientIp = client_ip(Req),
    handle_http_routed(Req, State, Method, Host, Path, Qs, T0, Vsn, Proto, TrackingId, ClientIp).

handle_http_routed(Req, State, Method, Host, Path, Qs, T0, Vsn, Proto, TrackingId, ClientIp) ->
    case pertisk_eproxy_router:route(Host, Path) of
        {error, no_route} ->
            inc_request_metrics(Host, Host, <<"404">>, Proto),
            H404 = maybe_add_alt_svc(
                Req,
                Host,
                with_tracking_id_header(TrackingId, #{<<"content-type">> => <<"text/plain">>})
            ),
            Body404 = <<"No route found for host: ", Host/binary>>,
            {H404Out, Body404Out} =
                pertisk_eproxy_compression:maybe_compress_cowboy(404, Req, H404, Body404),
            Req2 = cowboy_req:reply(404, H404Out, Body404Out, Req),
            log_access(Host, Host, Method, Path, 404, T0, Vsn, <<>>),
            {ok, Req2, State};
        {ok, #{upstream_path := UpstreamPath, backend := BackendName, site_host := SiteHost}} ->
            case pertisk_eproxy_rate_limit:check(ClientIp, Host, SiteHost) of
                deny ->
                    inc_request_metrics(Host, SiteHost, <<"429">>, Proto),
                    H429 = with_tracking_id_header(TrackingId, #{<<"content-type">> => <<"text/plain">>}),
                    Req2 = cowboy_req:reply(429, H429, <<"Too Many Requests">>, Req),
                    log_access(Host, SiteHost, Method, Path, 429, T0, Vsn, <<>>),
                    {ok, Req2, State};
                allow ->
                    case authorize_proxy_request(SiteHost, Method, Path, Qs, Req, ClientIp) of
                        {error, {auth_denied, Status}} ->
                            inc_request_metrics(Host, SiteHost, integer_to_binary(Status), Proto),
                            Req2 = cowboy_req:reply(Status, #{}, <<>>, Req),
                            log_access(Host, SiteHost, Method, Path, Status, T0, Vsn, <<>>),
                            {ok, Req2, State};
                        {error, auth_unreachable} ->
                            inc_request_metrics(Host, SiteHost, <<"502">>, Proto),
                            Req2 = cowboy_req:reply(502, #{}, <<"Auth service unreachable">>, Req),
                            log_access(Host, SiteHost, Method, Path, 502, T0, Vsn, <<>>),
                            {ok, Req2, State};
                        ok ->
                            proxy_matched_route(
                                Req, State, Method, Host, Path, Qs, T0, Vsn, Proto, TrackingId,
                                ClientIp, UpstreamPath, BackendName, SiteHost
                            )
                    end
            end
    end.

proxy_matched_route(
    Req, State, Method, Host, Path, Qs, T0, Vsn, Proto, TrackingId,
    ClientIp, UpstreamPath, BackendName, SiteHost
) when is_binary(UpstreamPath), is_binary(BackendName) ->
            case pertisk_eproxy_config:backend_is_management_only(BackendName) of
                true ->
                    case proxy_local_management(
                        Req, Method, Host, SiteHost, UpstreamPath, Qs, ClientIp, TrackingId, Proto
                    ) of
                        {ok, StatusCode, Req2} ->
                            StatusBin = integer_to_binary(StatusCode),
                            inc_request_metrics(Host, SiteHost, StatusBin, Proto),
                            log_access(
                                Host,
                                SiteHost,
                                Method,
                                Path,
                                StatusCode,
                                T0,
                                Vsn,
                                pertisk_eproxy_config:management_loopback_upstream_bin()
                            ),
                            {ok, Req2, State};
                        {error, Reason} ->
                            inc_request_metrics(Host, SiteHost, <<"502">>, Proto),
                            lager:warning("Local management proxy error ~p for ~s~s", [Reason, Host, Path]),
                            H502 = maybe_add_alt_svc(
                                Req,
                                Host,
                                with_tracking_id_header(TrackingId, #{<<"content-type">> => <<"text/plain">>})
                            ),
                            Body502 = <<"Bad Gateway">>,
                            {H502Out, Body502Out} =
                                pertisk_eproxy_compression:maybe_compress_cowboy(502, Req, H502, Body502),
                            Req2 = cowboy_req:reply(502, H502Out, Body502Out, Req),
                            log_access(Host, SiteHost, Method, Path, 502, T0, Vsn, <<>>),
                            {ok, Req2, State}
                    end;
                false ->
                    case pertisk_eproxy_backend:pick_upstream(BackendName, ClientIp) of
                {error, no_healthy_upstream} ->
                    case maybe_proxy_via_local_management(
                        Req,
                        Method,
                        Host,
                                SiteHost,
                        UpstreamPath,
                        Qs,
                        ClientIp,
                        TrackingId
                    ) of
                        {ok, StatusCode, Req2} ->
                            StatusBin = integer_to_binary(StatusCode),
                            inc_request_metrics(Host, SiteHost, StatusBin, Proto),
                            log_access(
                                Host,
                                SiteHost,
                                Method,
                                Path,
                                StatusCode,
                                T0,
                                Vsn,
                                pertisk_eproxy_config:management_loopback_upstream_bin()
                            ),
                            {ok, Req2, State};
                        _ ->
                            inc_request_metrics(Host, SiteHost, <<"502">>, Proto),
                            H502 = maybe_add_alt_svc(
                                Req,
                                Host,
                                with_tracking_id_header(TrackingId, #{<<"content-type">> => <<"text/plain">>})
                            ),
                            Body502 = <<"Bad Gateway: no healthy upstream">>,
                            {H502Out, Body502Out} =
                                pertisk_eproxy_compression:maybe_compress_cowboy(502, Req, H502, Body502),
                            Req2 = cowboy_req:reply(502, H502Out, Body502Out, Req),
                            log_access(Host, SiteHost, Method, Path, 502, T0, Vsn, <<>>),
                            {ok, Req2, State}
                    end;
                {ok, UpstreamAddr} ->
                    Result = proxy_request(Req, Method, Host, SiteHost, UpstreamPath, Qs,
                                           UpstreamAddr, ClientIp, TrackingId),
                    case Result of
                        {ok, StatusCode, Req2} ->
                            StatusBin = integer_to_binary(StatusCode),
                            inc_request_metrics(Host, SiteHost, StatusBin, Proto),
                            pertisk_eproxy_backend:done_upstream(BackendName, UpstreamAddr, ok),
                            log_access(Host, SiteHost, Method, Path, StatusCode, T0, Vsn, UpstreamAddr),
                            {ok, Req2, State};
                            {ok_stream_aborted, StatusCode, Req2} ->
                                %% Response headers were already sent and the stream was
                                %% finalized locally. Do not penalize backend health here:
                                %% some upstreams (notably Kubernetes watch-style APIs)
                                %% periodically close streams, and treating this as a hard
                                %% backend failure causes false circuit-breaker trips.
                                StatusBin = integer_to_binary(StatusCode),
                                inc_request_metrics(Host, SiteHost, StatusBin, Proto),
                                pertisk_eproxy_backend:done_upstream(BackendName, UpstreamAddr, ok),
                                log_access(Host, SiteHost, Method, Path, StatusCode, T0, Vsn, UpstreamAddr),
                                {ok, Req2, State};
                        {error, Reason} ->
                            pertisk_eproxy_backend:done_upstream(BackendName, UpstreamAddr, error),
                            case maybe_proxy_via_local_management(
                                Req,
                                Method,
                                Host,
                                SiteHost,
                                UpstreamPath,
                                Qs,
                                ClientIp,
                                TrackingId
                            ) of
                                {ok, StatusCode, Req2} ->
                                    StatusBin = integer_to_binary(StatusCode),
                                    inc_request_metrics(Host, SiteHost, StatusBin, Proto),
                                    log_access(
                                        Host,
                                        SiteHost,
                                        Method,
                                        Path,
                                        StatusCode,
                                        T0,
                                        Vsn,
                                        pertisk_eproxy_config:management_loopback_upstream_bin()
                                    ),
                                    {ok, Req2, State};
                                _ ->
                                    inc_request_metrics(Host, SiteHost, <<"502">>, Proto),
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
                                    log_access(Host, SiteHost, Method, Path, 502, T0, Vsn, UpstreamAddr),
                                    {ok, Req2, State}
                            end
                    end
            end
    end.

maybe_proxy_via_local_management(Req, Method, Host, Site, UpstreamPath, Qs, ClientIp, TrackingId) ->
    case should_try_local_management_fallback(Host, UpstreamPath) of
        false ->
            no_fallback;
        true ->
            proxy_local_management(
                Req, Method, Host, Site, UpstreamPath, Qs, ClientIp, TrackingId, request_proto_metric(Req)
            )
    end.

proxy_local_management(Req, Method, Host, _Site, UpstreamPath, Qs, ClientIp, TrackingId, _Proto) ->
    {ok, Body} = read_body(Req),
    MethodBin =
        case Method of
            M when is_binary(M) -> M;
            M when is_list(M) -> iolist_to_binary(M);
            M when is_atom(M) -> atom_to_binary(M, utf8);
            _ -> <<"GET">>
        end,
    H3Headers = cowboy_headers_to_h3(cowboy_req:headers(Req)),
    case pertisk_eproxy_h3_local_admin:try_dispatch(
        MethodBin, Host, UpstreamPath, Qs, H3Headers, Body, ClientIp
    ) of
        {ok, Status, RespHeaders, RespBody} ->
            HeadersMap = h3_response_headers_to_cowboy(RespHeaders),
            Headers1 = with_tracking_id_header(Req, HeadersMap),
            Headers2 = maybe_add_alt_svc(Req, Host, Headers1),
            {OutHeaders, OutBody} =
                pertisk_eproxy_compression:maybe_compress_cowboy(Status, Req, Headers2, RespBody),
            Req2 = cowboy_req:reply(Status, OutHeaders, OutBody, Req),
            {ok, Status, Req2};
        {error, unsupported} ->
            case is_admin_realtime_sse_path(UpstreamPath) of
                true ->
                    proxy_admin_realtime_sse(Req, Host, TrackingId);
                false ->
                    Mgmt = pertisk_eproxy_config:management_loopback_upstream_bin(),
                    proxy_request(Req, Method, Host, Host, UpstreamPath, Qs, Mgmt, ClientIp, TrackingId)
            end;
        {error, Reason} ->
            {error, Reason}
    end.

is_admin_realtime_sse_path(<<"/api/realtime-sse">>) ->
    true;
is_admin_realtime_sse_path(<<"/api/realtime-sse/", _/binary>>) ->
    true;
is_admin_realtime_sse_path(_) ->
    false.

proxy_admin_realtime_sse(Req, Host, TrackingId) ->
    case pertisk_eproxy_admin_sse_handler:authorize(Req) of
        {error, unauthorized} ->
            Headers = with_tracking_id_header(
                TrackingId,
                pertisk_eproxy_response_headers:merge(#{<<"content-type">> => <<"application/json">>})
            ),
            Req2 = cowboy_req:reply(401, Headers, <<"{\"error\":\"Unauthorized\"}">>, Req),
            {ok, 401, Req2};
        ok ->
            case pertisk_eproxy_admin_sse_handler:stream_authorized(Req) of
                {ok, Req2} ->
                    {ok, 200, Req2};
                {error, Reason} ->
                    lager:warning("admin realtime-sse stream error for ~s: ~p", [Host, Reason]),
                    Headers = with_tracking_id_header(
                        TrackingId,
                        pertisk_eproxy_response_headers:merge(#{<<"content-type">> => <<"text/plain">>})
                    ),
                    Req2 = cowboy_req:reply(500, Headers, <<"Internal Server Error">>, Req),
                    {ok, 500, Req2}
            end
    end.

cowboy_headers_to_h3(Headers) when is_map(Headers) ->
    [
        {K, V}
     || {K, V} <- maps:to_list(Headers),
        is_binary(K),
        is_binary(V)
    ];
cowboy_headers_to_h3(_) ->
    [].

h3_response_headers_to_cowboy(Headers) when is_list(Headers) ->
    maps:from_list([
        {string:lowercase(K), V}
     || {K, V} <- Headers,
        is_binary(K),
        is_binary(V)
    ]).

should_try_local_management_fallback(Host, _Path) ->
    LowerHost = string:lowercase(Host),
    binary:match(LowerHost, <<"admin.">>) =:= {0, byte_size(<<"admin.">>)}.

log_access(Host, Site, Method, Path, Status, T0, Vsn, Upstream) ->
    Dt = max(0, erlang:monotonic_time(millisecond) - T0),
    catch pertisk_eproxy_access_log:log_proxy(Host, Method, Path, Status, Dt, Vsn, Upstream, Site).

inc_request_metrics(Host, Site, StatusCode, Proto) ->
    ok = pertisk_eproxy_metrics:inc_request(Host, StatusCode, Proto),
    ok = pertisk_eproxy_metrics:inc_site_request(Site, StatusCode, Proto).

%% -------------------------------------------------------------------------
%% Core proxy logic using gun
%% -------------------------------------------------------------------------

proxy_request(Req, Method, Host, Site, UpstreamPath, Qs, UpstreamAddr, ClientIp, TrackingId) ->
    ReqKind = detect_request_kind(Req, Site),
    case ReqKind of
        eventstream ->
            proxy_eventstream_request(
                Req, Method, Host, Site, UpstreamPath, Qs, UpstreamAddr, ClientIp, TrackingId
            );
        _ ->
            proxy_request_impl(
                Req, Method, Host, Site, UpstreamPath, Qs, UpstreamAddr, ClientIp, TrackingId, ReqKind
            )
    end.

proxy_eventstream_request(Req, Method, Host, Site, UpstreamPath, Qs, UpstreamAddr, ClientIp, TrackingId) ->
    {UpHost0, UpPort0, Transport0} = parse_upstream(UpstreamAddr),
    FullPath = case Qs of
        <<>> -> UpstreamPath;
        _    -> <<UpstreamPath/binary, "?", Qs/binary>>
    end,
    {ok, Body} = read_body(Req),
    with_eventstream_upstream(
        fun(ConnPid, #{host := UpHost, port := UpPort, transport := Transport, gun_opts := GunOpts}) ->
            do_proxy(
                Req,
                ConnPid,
                Method,
                Host,
                Site,
                FullPath,
                ClientIp,
                TrackingId,
                Body,
                UpHost,
                UpPort,
                Transport,
                eventstream,
                GunOpts,
                0,
                true
            )
        end,
        UpHost0,
        UpPort0,
        Transport0,
        UpstreamPath
    ).

proxy_request_impl(Req, Method, Host, Site, UpstreamPath, Qs, UpstreamAddr, ClientIp, TrackingId, ReqKind) ->
    case pertisk_eproxy_config:is_management_upstream_addr(UpstreamAddr) of
        true ->
            proxy_local_management(
                Req,
                Method,
                Host,
                Site,
                UpstreamPath,
                Qs,
                ClientIp,
                TrackingId,
                request_proto_metric(Req)
            );
        false ->
            proxy_request_impl_upstream(
                Req,
                Method,
                Host,
                Site,
                UpstreamPath,
                Qs,
                UpstreamAddr,
                ClientIp,
                TrackingId,
                ReqKind
            )
    end.

proxy_request_impl_upstream(Req, Method, Host, Site, UpstreamPath, Qs, UpstreamAddr, ClientIp, TrackingId, ReqKind) ->
    {UpHost, UpPort, Transport} = parse_upstream(UpstreamAddr),
    FullPath = case Qs of
        <<>> -> UpstreamPath;
        _    -> <<UpstreamPath/binary, "?", Qs/binary>>
    end,
    UseEphemeralConn = should_use_ephemeral_connection(ReqKind, Host, UpHost, UpPort, Transport),
    GunOpts = upstream_gun_opts_with_port(UpHost, UpPort, Transport, ReqKind),
    {ok, Body} = read_body(Req),

    case checkout_or_open_connection(
        UseEphemeralConn,
        UpHost,
        UpPort,
        Transport,
        ReqKind,
        GunOpts
    ) of
        {error, Reason} ->
            {error, Reason};
        {ok, ConnPid} ->
            case do_proxy(
                Req,
                ConnPid,
                Method,
                Host,
                Site,
                FullPath,
                ClientIp,
                TrackingId,
                Body,
                UpHost,
                UpPort,
                Transport,
                ReqKind,
                GunOpts,
                0,
                UseEphemeralConn
            ) of
                {error, Reason} = Err ->
                    case should_retry_http1_fallback(Reason, ReqKind, Transport, GunOpts) of
                        true ->
                            lager:warning(
                                "Upstream protocol fallback to HTTP/1.1 for ~s~s -> ~s (reason=~p)",
                                [Host, UpstreamPath, UpstreamAddr, Reason]
                            ),
                            retry_with_http1(
                                Req,
                                Method,
                                Host,
                                Site,
                                FullPath,
                                ClientIp,
                                TrackingId,
                                Body,
                                UpHost,
                                UpPort,
                                ReqKind,
                                GunOpts
                            );
                        false ->
                            Err
                    end;
                Ok ->
                    Ok
            end
    end.

retry_with_http1(
    Req,
    Method,
    Host,
    Site,
    FullPath,
    ClientIp,
    TrackingId,
    Body,
    UpHost,
    UpPort,
    ReqKind,
    GunOpts
) ->
    GunOptsHttp1 = GunOpts#{protocols => [http]},
    case checkout_or_open_connection(true, UpHost, UpPort, tcp, ReqKind, GunOptsHttp1) of
        {error, Reason2} ->
            {error, Reason2};
        {ok, ConnPid2} ->
            do_proxy(
                Req,
                ConnPid2,
                Method,
                Host,
                Site,
                FullPath,
                ClientIp,
                TrackingId,
                Body,
                UpHost,
                UpPort,
                tcp,
                ReqKind,
                GunOptsHttp1,
                1,
                true
            )
    end.

should_retry_http1_fallback(Reason, ReqKind, Transport, GunOpts) ->
    ReqKind =/= grpc
        andalso Transport =:= tcp
        andalso lists:member(http2, maps:get(protocols, GunOpts, []))
        andalso is_http2_preface_error(Reason).

is_http2_preface_error({connection_error, {protocol_error, Msg}}) ->
    is_invalid_preface_text(Msg);
is_http2_preface_error({await_up, {connection_error, {protocol_error, Msg}}}) ->
    is_invalid_preface_text(Msg);
is_http2_preface_error({await_up, {error, {protocol_error, Msg}}}) ->
    is_invalid_preface_text(Msg);
is_http2_preface_error({connect, {protocol_error, Msg}}) ->
    is_invalid_preface_text(Msg);
is_http2_preface_error({await_response, {connection_error, {protocol_error, Msg}}}) ->
    is_invalid_preface_text(Msg);
is_http2_preface_error({stream_error, {connection_error, {protocol_error, Msg}}}) ->
    is_invalid_preface_text(Msg);
is_http2_preface_error(_) ->
    false.

is_invalid_preface_text(Msg) when is_list(Msg) ->
    string:find(Msg, "Invalid connection preface") =/= nomatch;
is_invalid_preface_text(Msg) when is_binary(Msg) ->
    binary:match(Msg, <<"Invalid connection preface">>) =/= nomatch;
is_invalid_preface_text(Msg) when is_atom(Msg) ->
    is_invalid_preface_text(atom_to_list(Msg));
is_invalid_preface_text(_) ->
    false.

checkout_or_open_connection(true, UpHost, UpPort, _Transport, _ReqKind, GunOpts) ->
    open_direct_connection(UpHost, UpPort, GunOpts);
checkout_or_open_connection(false, UpHost, UpPort, Transport, ReqKind, GunOpts) ->
    pertisk_eproxy_upstream_pool:checkout(UpHost, UpPort, Transport, ReqKind, GunOpts).

open_direct_connection(UpHost, UpPort, GunOpts) ->
    case gun:open(UpHost, UpPort, GunOpts) of
        {ok, ConnPid} ->
            Timeout = maps:get(connect_timeout, GunOpts, ?CONNECT_TIMEOUT),
            case gun:await_up(ConnPid, Timeout) of
                {ok, _Proto} ->
                    {ok, ConnPid};
                {error, Reason} ->
                    catch gun:close(ConnPid),
                    {error, {await_up, Reason}}
            end;
        {error, Reason} ->
            {error, {connect, Reason}}
    end.

should_use_ephemeral_connection(eventstream, _Host, _UpHost, _UpPort, _Transport) ->
    %% Long-lived SSE streams must not reuse pooled upstream sockets that may
    %% have been half-closed by idle timers or prior responses.
    true;
should_use_ephemeral_connection(grpc, _Host, _UpHost, _UpPort, _Transport) ->
    false;
should_use_ephemeral_connection(_ReqKind, _Host, UpHost, _UpPort, _Transport) ->
    %% Loopback HTTP upstreams are sensitive to stale pooled sockets and can
    %% fall into the 15s loopback timeout path before Gun retries kick in.
    %% Use a fresh connection for any non-gRPC loopback request, while keeping
    %% gRPC on the shared pool for stream reuse. Bench mode sets
    %% `upstream_loopback_pool_enabled' to measure pooled keep-alive throughput.
    %%
    is_loopback_host(UpHost) andalso not loopback_pool_enabled().

loopback_pool_enabled() ->
    maps:get(upstream_loopback_pool_enabled, pertisk_eproxy_config:get_config(), false).

is_loopback_host(Host) when is_binary(Host) ->
    is_loopback_host(binary_to_list(Host));
is_loopback_host(Host) when is_list(Host) ->
    H = string:lowercase(string:trim(Host)),
    H =:= "127.0.0.1" orelse H =:= "localhost" orelse H =:= "::1";
is_loopback_host(_) ->
    false.

upstream_gun_opts(UpHost, tls, ReqKind) ->
    Base = #{
        transport => tls,
        protocols => gun_protocols_for_request(ReqKind, tls),
        connect_timeout => connect_timeout_ms(UpHost, ReqKind),
        tls_opts => upstream_tls_opts(UpHost)
    },
    add_request_profile_upstream_opts(ReqKind, Base);
upstream_gun_opts(_UpHost, Transport, ReqKind) ->
    Base = #{
        transport => Transport,
        protocols => gun_protocols_for_request(ReqKind, Transport),
        connect_timeout => connect_timeout_ms(_UpHost, ReqKind)
    },
    add_request_profile_upstream_opts(ReqKind, Base).

upstream_gun_opts_with_port(UpHost, UpPort, Transport, ReqKind) ->
    Base = upstream_gun_opts(UpHost, Transport, ReqKind),
    Base#{protocols => gun_protocols_for_request(ReqKind, Transport, UpPort)}.

connect_timeout_ms(UpHost, ReqKind) ->
    Config = pertisk_eproxy_config:get_config(),
    case ReqKind =/= grpc andalso is_loopback_host(UpHost) andalso not loopback_pool_enabled() of
        true ->
            case maps:get(upstream_loopback_connect_timeout_ms, Config, 3000) of
                N when is_integer(N), N > 0 -> N;
                _ -> 3000
            end;
        false ->
            ?CONNECT_TIMEOUT
    end.

add_request_profile_upstream_opts(eventstream, GunOpts) ->
    GunOpts#{
        tcp_opts => [{keepalive, true}, {nodelay, true}],
        http2_opts => #{
            keepalive => ?GRPC_HTTP2_KEEPALIVE_MS,
            keepalive_tolerance => ?GRPC_HTTP2_KEEPALIVE_TOLERANCE
        }
    };
add_request_profile_upstream_opts(grpc, GunOpts) ->
    GunOpts#{
        tcp_opts => [{keepalive, true}, {nodelay, true}],
        http2_opts => #{
            keepalive => ?GRPC_HTTP2_KEEPALIVE_MS,
            keepalive_tolerance => ?GRPC_HTTP2_KEEPALIVE_TOLERANCE
        }
    };
add_request_profile_upstream_opts(_, GunOpts) ->
    %% Keep TCP sockets responsive for regular HTTP requests as well.
    GunOpts#{tcp_opts => [{keepalive, true}, {nodelay, true}]}. 

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
    Site,
    FullPath,
    ClientIp,
    TrackingId,
    Body,
    UpHost,
    UpPort,
    Transport,
    ReqKind,
    GunOpts,
    RetryCount,
    UseEphemeralConn
) ->
    HeadersMap = forward_headers(Req, Host, ClientIp, FullPath, TrackingId),
    Headers = maps:to_list(HeadersMap),
    ReqBodyBytes = byte_size(Body),
    TimeoutMs = request_timeout_ms(Req, ReqKind, Host, UpHost),

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
                        Site,
                        TrackingId,
                        ReqBodyBytes
                    );
                _ ->
                    FirstAwaitMs =
                        case ReqKind of
                            eventstream -> sse_initial_headers_timeout_ms();
                            _ -> TimeoutMs
                        end,
                    case gun:await(ConnPid, StreamRef, FirstAwaitMs) of
                        {response, nofin, Status, RespHeaders} ->
                            do_proxy_http_streaming(
                                Req,
                                ConnPid,
                                StreamRef,
                                Status,
                                RespHeaders,
                                Host,
                                Site,
                                TrackingId,
                                ReqBodyBytes
                            );
                        {response, fin, Status, RespHeaders} ->
                            ok = record_proxy_bytes_metrics(Host, Site, ReqBodyBytes, 0),
                            {Req1, RawHeaders} = response_headers_to_req(Req, RespHeaders),
                            CowboyHeaders = maybe_add_alt_svc(Req1, Host, RawHeaders),
                            Req2 = reply_upstream_fin(Method, Status, with_tracking_id_header(TrackingId, CowboyHeaders), Req1),
                            {ok, Status, Req2};
                        {error, timeout} when ReqKind =:= eventstream ->
                            ReqPath = cowboy_req:path(Req),
                            case should_sse_early_flush(Host, ReqPath, HeadersMap) of
                                true ->
                                    do_proxy_sse_idle_upstream(
                                        Req,
                                        ConnPid,
                                        StreamRef,
                                        Host,
                                        Site,
                                        TrackingId,
                                        ReqBodyBytes
                                    );
                                false ->
                                    {error, timeout}
                            end;
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
            case should_retry_proxy_error(RetryCount, ReqKind, ProxyReason, UpHost) of
                true ->
                    case checkout_or_open_connection(
                        UseEphemeralConn,
                        UpHost,
                        UpPort,
                        Transport,
                        ReqKind,
                        GunOpts
                    ) of
                        {ok, ConnPid2} ->
                            do_proxy(
                                Req,
                                ConnPid2,
                                Method,
                                Host,
                                Site,
                                FullPath,
                                ClientIp,
                                TrackingId,
                                Body,
                                UpHost,
                                UpPort,
                                Transport,
                                ReqKind,
                                GunOpts,
                                RetryCount + 1,
                                UseEphemeralConn
                            );
                        {error, _} = RetryErr ->
                            RetryErr
                    end;
                false ->
                    maybe_invalidate_ephemeral_connection(ConnPid, UseEphemeralConn),
                    {error, ProxyReason}
            end;
        _ ->
            maybe_invalidate_ephemeral_connection(ConnPid, UseEphemeralConn),
            Result
    end.

maybe_invalidate_ephemeral_connection(ConnPid, true) ->
    pertisk_eproxy_upstream_pool:invalidate(ConnPid);
maybe_invalidate_ephemeral_connection(_ConnPid, false) ->
    ok.

should_retry_proxy_error(RetryCount, ReqKind, ProxyReason, UpHost) ->
    ReqKind =/= grpc
        andalso retryable_upstream_error(ProxyReason)
        andalso RetryCount < max_proxy_retries(ProxyReason, UpHost).

max_proxy_retries({down, shutdown}, UpHost) ->
    case is_loopback_host(UpHost) of
        true -> 1;
        false -> 1
    end;
max_proxy_retries(_ProxyReason, _UpHost) ->
    1.

do_proxy_grpc_streaming(Req, ConnPid, StreamRef, Host, Site, TrackingId, ReqBodyBytes) ->
    case is_stream_endpoint_request(Req) of
        true ->
            lager:error(
                "stream_misroute_grpc path=~p tracking_id=~p",
                [cowboy_req:path(Req), TrackingId]
            );
        false ->
            ok
    end,
    %% gRPC watch/stream calls may stay idle before the first message; do not
    %% enforce the generic HTTP request timeout on initial response await.
    case gun:await(ConnPid, StreamRef, infinity) of
        {response, nofin, Status, RespHeaders} ->
            {Req1, RawHeaders} = response_headers_to_req(Req, RespHeaders),
            %% Avoid advertising H3 for gRPC streams. The H3 gateway intentionally
            %% rejects gRPC with 421, so advertising Alt-Svc here causes needless
            %% protocol churn and noisy 421 retries from some clients.
            CowboyHeaders = pertisk_eproxy_response_headers:merge(RawHeaders),
            StreamReq = cowboy_req:stream_reply(
                Status,
                with_tracking_id_header(TrackingId, CowboyHeaders),
                Req1
            ),
            proxy_grpc_stream_loop(ConnPid, StreamRef, StreamReq, Host, Site, ReqBodyBytes, 0, Status);
        {response, fin, Status, RespHeaders} ->
            {Req1, RawHeaders} = response_headers_to_req(Req, RespHeaders),
            CowboyHeaders = pertisk_eproxy_response_headers:merge(RawHeaders),
            Req2 = cowboy_req:reply(Status, with_tracking_id_header(TrackingId, CowboyHeaders), <<>>, Req1),
            ok = record_proxy_bytes_metrics(Host, Site, ReqBodyBytes, 0),
            {ok, Status, Req2};
        {error, Reason} ->
            {error, Reason};
        Other ->
            {error, {await_response_unexpected, Other}}
    end.

%% For long-lived chunked HTTP responses (for example Kubernetes watch APIs),
%% stream upstream body chunks directly to the client instead of waiting for a
%% terminal body frame that may arrive after much longer than REQUEST_TIMEOUT.
%% Argo CD (and similar) may hold SSE response headers until the first watch
%% event. Flush an early 200 + heartbeat so browsers keep the EventSource open.
do_proxy_sse_idle_upstream(Req, ConnPid, StreamRef, Host, Site, TrackingId, ReqBodyBytes) ->
    ReqPath = cowboy_req:path(Req),
    IsStreamEndpoint = is_stream_endpoint_request(Req),
    StartMs = erlang:monotonic_time(millisecond),
    maybe_log_stream_lifecycle(
        IsStreamEndpoint,
        stream_open,
        #{
            tracking_id => TrackingId,
            path => ReqPath,
            status => 200,
            event_stream => true,
            early_flush => true
        }
    ),
    EarlyHeaders = normalize_event_stream_headers([]),
    StreamReq = cowboy_req:stream_reply(
        200,
        with_tracking_id_header(TrackingId, EarlyHeaders),
        Req
    ),
    ok = cowboy_req:stream_body(<<": connected\n\n">>, nofin, StreamReq),
    HeartbeatMs = stream_await_timeout(true),
    proxy_sse_idle_upstream_await(
        ConnPid,
        StreamRef,
        StreamReq,
        Host,
        Site,
        ReqBodyBytes,
        HeartbeatMs,
        IsStreamEndpoint,
        TrackingId,
        ReqPath,
        StartMs
    ).

proxy_sse_idle_upstream_await(
    ConnPid,
    StreamRef,
    StreamReq,
    Host,
    Site,
    ReqBodyBytes,
    HeartbeatMs,
    IsStreamEndpoint,
    TrackingId,
    ReqPath,
    StartMs
) ->
    case gun:await(ConnPid, StreamRef, HeartbeatMs) of
        {response, nofin, Status, _RespHeaders} ->
            proxy_http_stream_loop(
                ConnPid,
                StreamRef,
                StreamReq,
                Host,
                Site,
                ReqBodyBytes,
                0,
                Status,
                true,
                IsStreamEndpoint,
                TrackingId,
                ReqPath,
                StartMs
            );
        {response, fin, Status, _RespHeaders} ->
            Body =
                case gun:await_body(ConnPid, StreamRef, 5000) of
                    {ok, B} -> iolist_to_binary(B);
                    {ok, B, _} -> iolist_to_binary(B);
                    _ -> <<>>
                end,
            RespBytes = byte_size(Body),
            ok = cowboy_req:stream_body(Body, fin, StreamReq),
            ok = record_proxy_bytes_metrics(Host, Site, ReqBodyBytes, RespBytes),
            {ok, Status, StreamReq};
        {error, timeout} ->
            ok = cowboy_req:stream_body(<<":\n\n">>, nofin, StreamReq),
            proxy_sse_idle_upstream_await(
                ConnPid,
                StreamRef,
                StreamReq,
                Host,
                Site,
                ReqBodyBytes,
                HeartbeatMs,
                IsStreamEndpoint,
                TrackingId,
                ReqPath,
                StartMs
            );
        {error, Reason} ->
            ok = cowboy_req:stream_body(<<>>, fin, StreamReq),
            {error, Reason};
        Other ->
            {error, {await_response_unexpected, Other}}
    end.

do_proxy_http_streaming(Req, ConnPid, StreamRef, Status, RespHeaders, Host, Site, TrackingId, ReqBodyBytes) ->
    {Req1, RawHeaders} = response_headers_to_req(Req, RespHeaders),
    ReqPath = cowboy_req:path(Req),
    IsStreamEndpoint = is_stream_endpoint_request(Req),
    WantsEventStream = is_event_stream_request(Req),
    ForceEventStream = WantsEventStream orelse IsStreamEndpoint,
    IsEventStream = is_event_stream_response(RespHeaders) orelse ForceEventStream,
    StartMs = erlang:monotonic_time(millisecond),
    maybe_log_stream_lifecycle(
        IsStreamEndpoint,
        stream_open,
        #{
            tracking_id => TrackingId,
            path => ReqPath,
            status => Status,
            event_stream => IsEventStream
        }
    ),
    StreamHeaders0 =
        case IsStreamEndpoint of
            true -> normalize_http_stream_headers(RawHeaders);
            false -> RawHeaders
        end,
    StreamHeaders1 =
        case IsEventStream of
            true -> normalize_event_stream_headers(StreamHeaders0);
            false -> StreamHeaders0
        end,
    CowboyHeaders =
        case IsStreamEndpoint of
            true -> StreamHeaders1;
            false -> maybe_add_alt_svc(Req1, Host, StreamHeaders1)
        end,
    StreamReq = cowboy_req:stream_reply(
        Status,
        with_tracking_id_header(TrackingId, CowboyHeaders),
        Req1
    ),
    case IsEventStream of
        true ->
            %% Flush an initial SSE comment so clients/proxies consider the
            %% stream established even when upstream is initially idle.
            ok = cowboy_req:stream_body(<<": connected\n\n">>, nofin, StreamReq);
        false when WantsEventStream =:= true ->
            lager:debug("accept=text/event-stream but upstream content-type is not SSE");
        false ->
            ok
    end,
    proxy_http_stream_loop(
        ConnPid,
        StreamRef,
        StreamReq,
        Host,
        Site,
        ReqBodyBytes,
        0,
        Status,
        IsEventStream,
        IsStreamEndpoint,
        TrackingId,
        ReqPath,
        StartMs
    ).

%% For HEAD requests: upstream's Content-Length reflects what GET would return.
%% Cowboy's reply/4 computes CL from byte_size(Body), then do_reply/4 pattern-
%% matches method=HEAD and suppresses the body entirely (sends HEADERS+END_STREAM
%% with no DATA frame).  By passing a fake body of UpstreamCL bytes we get:
%%   - content-length = UpstreamCL (correct, not 0)
%%   - HEADERS frame with END_STREAM=true (no DATA frame at all)
%% This fixes both docker-buildx-imagetools (CL=0 → skip GET → empty JSON) and
%% containerd (stricter HTTP/2: rejects DATA-after-END_STREAM on HEAD streams).
%%
%% HTTP/1.1 HEAD benefits identically: Cowboy sends headers with the correct
%% CL and no body, keeping keep-alive connections healthy.
reply_upstream_fin(<<"HEAD">>, Status, Headers, Req) ->
    UpstreamCL = binary_to_integer(
        maps:get(<<"content-length">>, Headers, <<"0">>)),
    FakeBody = binary:copy(<<0>>, UpstreamCL),
    cowboy_req:reply(Status, maps:remove(<<"content-length">>, Headers), FakeBody, Req);
reply_upstream_fin(_Method, Status, Headers, Req) ->
    cowboy_req:reply(Status, Headers, <<>>, Req).

proxy_http_stream_loop(
    ConnPid,
    StreamRef,
    Req,
    Host,
    Site,
    ReqBodyBytes,
    RespBytes,
    Status,
    IsEventStream,
    IsStreamEndpoint,
    TrackingId,
    ReqPath,
    StartMs
) ->
    AwaitTimeout = stream_await_timeout(IsEventStream),
    case gun:await(ConnPid, StreamRef, AwaitTimeout) of
        {data, nofin, Chunk} ->
            ChunkBin = iolist_to_binary(Chunk),
            ok = cowboy_req:stream_body(ChunkBin, nofin, Req),
            proxy_http_stream_loop(
                ConnPid,
                StreamRef,
                Req,
                Host,
                Site,
                ReqBodyBytes,
                RespBytes + byte_size(ChunkBin),
                Status,
                IsEventStream,
                IsStreamEndpoint,
                TrackingId,
                ReqPath,
                StartMs
            );
        {data, fin, Chunk} ->
            ChunkBin = iolist_to_binary(Chunk),
            ok = cowboy_req:stream_body(ChunkBin, fin, Req),
            FinalRespBytes = RespBytes + byte_size(ChunkBin),
            ok = record_proxy_bytes_metrics(Host, Site, ReqBodyBytes, FinalRespBytes),
            maybe_log_stream_lifecycle(
                IsStreamEndpoint,
                stream_fin,
                #{
                    tracking_id => TrackingId,
                    path => ReqPath,
                    status => Status,
                    duration_ms => erlang:monotonic_time(millisecond) - StartMs,
                    resp_bytes => FinalRespBytes
                }
            ),
            {ok, Status, Req};
        {trailers, Trailers} ->
            ok = maybe_stream_trailers(Req, Trailers),
            ok = record_proxy_bytes_metrics(Host, Site, ReqBodyBytes, RespBytes),
            maybe_log_stream_lifecycle(
                IsStreamEndpoint,
                stream_trailers,
                #{
                    tracking_id => TrackingId,
                    path => ReqPath,
                    status => Status,
                    duration_ms => erlang:monotonic_time(millisecond) - StartMs,
                    resp_bytes => RespBytes
                }
            ),
            {ok, Status, Req};
        {error, timeout} when IsEventStream =:= true ->
            %% Keep idle SSE/EventSource streams alive through intermediary
            %% idle timers by emitting a comment heartbeat frame.
            ok = cowboy_req:stream_body(<<":\n\n">>, nofin, Req),
            proxy_http_stream_loop(
                ConnPid,
                StreamRef,
                Req,
                Host,
                Site,
                ReqBodyBytes,
                RespBytes,
                Status,
                IsEventStream,
                IsStreamEndpoint,
                TrackingId,
                ReqPath,
                StartMs
            );
        {error, Reason} ->
            %% Response headers were already streamed to the client via stream_reply/3.
            %% Do not bubble this error up to the caller (which would attempt a second
            %% cowboy_req:reply/4 and crash Cowboy with an invalid command sequence).
            lager:info("Upstream stream ended after response started: ~p", [Reason]),
            pertisk_eproxy_upstream_pool:invalidate(ConnPid),
            _ = catch cowboy_req:stream_body(<<>>, fin, Req),
            ok = record_proxy_bytes_metrics(Host, Site, ReqBodyBytes, RespBytes),
            maybe_log_stream_lifecycle(
                IsStreamEndpoint,
                stream_error,
                #{
                    tracking_id => TrackingId,
                    path => ReqPath,
                    status => Status,
                    reason => Reason,
                    duration_ms => erlang:monotonic_time(millisecond) - StartMs,
                    resp_bytes => RespBytes
                }
            ),
            %% Return ok_stream_aborted so the caller can report error to the
            %% circuit breaker without attempting a second HTTP reply.
            {ok_stream_aborted, Status, Req};
        Other ->
            {error, {await_stream_unexpected, Other}}
    end.

stream_await_timeout(true) ->
    Config = pertisk_eproxy_config:get_config(),
    case maps:get(event_stream_heartbeat_ms, Config, ?DEFAULT_EVENT_STREAM_HEARTBEAT_MS) of
        N when is_integer(N), N > 0 -> N;
        _ -> ?DEFAULT_EVENT_STREAM_HEARTBEAT_MS
    end;
stream_await_timeout(false) ->
    infinity.

is_event_stream_response(RespHeaders) when is_list(RespHeaders) ->
    HeadersMap = maps:from_list(RespHeaders),
    case maps:get(<<"content-type">>, HeadersMap, <<>>) of
        Ct when is_binary(Ct) ->
            binary:match(string:lowercase(Ct), <<"text/event-stream">>) =/= nomatch;
        _ ->
            false
    end;
is_event_stream_response(_) ->
    false.

normalize_event_stream_headers(Headers) when is_map(Headers) ->
    %% SSE works best when intermediaries do not buffer/transform stream frames.
    Headers1 = maps:remove(<<"content-length">>, Headers),
    Headers2 = maps:remove(<<"transfer-encoding">>, Headers1),
    Headers2#{
        <<"content-type">> => <<"text/event-stream">>,
        <<"cache-control">> => <<"no-cache, no-transform">>,
        <<"connection">> => <<"keep-alive">>,
        <<"x-accel-buffering">> => <<"no">>
    };
normalize_event_stream_headers(Headers) ->
    Headers.

normalize_http_stream_headers(Headers) when is_map(Headers) ->
    %% Prevent buffering/compression side effects on long-lived watch streams.
    Headers1 = maps:remove(<<"content-length">>, Headers),
    Headers2 = maps:remove(<<"transfer-encoding">>, Headers1),
    Headers2#{
        <<"cache-control">> => <<"no-cache, no-transform">>,
        <<"x-accel-buffering">> => <<"no">>
    };
normalize_http_stream_headers(Headers) ->
    Headers.

maybe_log_stream_lifecycle(false, _Event, _Data) ->
    ok;
maybe_log_stream_lifecycle(true, Event, Data) ->
    lager:warning("stream_lifecycle ~p ~p", [Event, Data]).

proxy_grpc_stream_loop(ConnPid, StreamRef, Req, Host, Site, ReqBodyBytes, RespBytes, Status) ->
    case gun:await(ConnPid, StreamRef, infinity) of
        {data, nofin, Chunk} ->
            ChunkBin = iolist_to_binary(Chunk),
            ok = cowboy_req:stream_body(ChunkBin, nofin, Req),
            proxy_grpc_stream_loop(
                ConnPid,
                StreamRef,
                Req,
                Host,
                Site,
                ReqBodyBytes,
                RespBytes + byte_size(ChunkBin),
                Status
            );
        {data, fin, Chunk} ->
            ChunkBin = iolist_to_binary(Chunk),
            ok = cowboy_req:stream_body(ChunkBin, fin, Req),
            FinalRespBytes = RespBytes + byte_size(ChunkBin),
            ok = record_proxy_bytes_metrics(Host, Site, ReqBodyBytes, FinalRespBytes),
            {ok, Status, Req};
        {trailers, Trailers} ->
            ok = maybe_stream_trailers(Req, Trailers),
            ok = record_proxy_bytes_metrics(Host, Site, ReqBodyBytes, RespBytes),
            {ok, Status, Req};
        {error, Reason} ->
            %% gRPC headers have already been sent with stream_reply/3; finalize the
            %% existing stream instead of returning an error that would trigger a
            %% second HTTP reply attempt in the caller.
            lager:info("Upstream gRPC stream ended after response started: ~p", [Reason]),
            pertisk_eproxy_upstream_pool:invalidate(ConnPid),
            _ = catch cowboy_req:stream_body(<<>>, fin, Req),
            ok = record_proxy_bytes_metrics(Host, Site, ReqBodyBytes, RespBytes),
            {ok_stream_aborted, Status, Req};
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
retryable_upstream_error(timeout) -> true;
retryable_upstream_error({timeout, _}) -> true;
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

record_proxy_bytes_metrics(Host, Site, Recv, Sent) ->
    ok = pertisk_eproxy_metrics:record_proxy_bytes(Host, Recv, Sent),
    ok = pertisk_eproxy_metrics:record_site_bytes(Site, Recv, Sent).

%% -------------------------------------------------------------------------
%% Header helpers
%% -------------------------------------------------------------------------

forward_headers(Req, OrigHost, ClientIp, FullPath, TrackingId) ->
    InHeaders = cowboy_req:headers(Req),
    Proto     = forwarded_proto(Req, InHeaders),
    ProtoVsn  = version_to_bin(cowboy_req:version(Req)),
    ReqKind   = detect_request_kind(Req, OrigHost),

    %% Start from original headers, drop hop-by-hop
    Filtered0 = maps:without([<<"connection">>, <<"keep-alive">>, <<"te">>,
                              <<"trailers">>, <<"transfer-encoding">>,
                              <<"upgrade">>], InHeaders),
    Filtered =
        case is_stream_endpoint_path(FullPath) orelse ReqKind =:= eventstream of
            true -> maps:remove(<<"accept-encoding">>, Filtered0);
            false -> Filtered0
        end,

    %% gRPC over HTTP/2 expects `te: trailers`; preserve it when present.
    Filtered1 = maybe_restore_grpc_te_header(ReqKind, InHeaders, Filtered),

    %% Preserve original Host
    Base0 = Filtered1#{
        <<"host">>                     => OrigHost,
        <<"x-forwarded-host">>         => OrigHost,
        <<"x-forwarded-proto">>        => Proto,
        <<"x-forwarded-proto-version">> => ProtoVsn,
        <<"x-request-id">> => TrackingId
    },
    Base2 = maybe_add_eventstream_request_headers(ReqKind, maybe_add_argocd_bearer_from_cookie(Base0)),

    %% Proxmox console ticket endpoints may validate source identity across
    %% termproxy/vncproxy and vncwebsocket calls; avoid XFF drift between H3 and TCP.
    Headers1 =
        case skip_forwarded_for(OrigHost, FullPath) of
            true ->
                maps:remove(<<"x-forwarded-for">>, Base2);
            false ->
                XFF = case maps:find(<<"x-forwarded-for">>, Base2) of
                    {ok, Existing} -> <<Existing/binary, ", ", ClientIp/binary>>;
                    error          -> ClientIp
                end,
                Base2#{<<"x-forwarded-for">> => XFF}
        end,
    pertisk_eproxy_tracing:inject_headers(Headers1).

authorize_proxy_request(SiteHost, Method, Path, Qs, Req, ClientIp) ->
    Headers = cowboy_req:headers(Req),
    pertisk_eproxy_external_auth:authorize(SiteHost, Method, Path, Qs, Headers, ClientIp).

maybe_add_eventstream_request_headers(eventstream, Headers) when is_map(Headers) ->
    Headers#{
        <<"accept">> => <<"text/event-stream">>,
        <<"cache-control">> => <<"no-cache">>
    };
maybe_add_eventstream_request_headers(_, Headers) ->
    Headers.

maybe_add_argocd_bearer_from_cookie(Headers) when is_map(Headers) ->
    case maps:is_key(<<"authorization">>, Headers) of
        true ->
            Headers;
        false ->
            case maps:get(<<"cookie">>, Headers, undefined) of
                Cookie when is_binary(Cookie) ->
                    case extract_argocd_token_from_cookie(Cookie) of
                        {ok, Token} when Token =/= <<>> ->
                            Headers#{
                                <<"authorization">> => <<"Bearer ", Token/binary>>,
                                <<"cookie">> => Cookie
                            };
                        _ ->
                            Headers
                    end;
                _ ->
                    Headers
            end
    end;
maybe_add_argocd_bearer_from_cookie(Headers) ->
    Headers.

extract_argocd_token_from_cookie(CookieHeader) when is_binary(CookieHeader) ->
    case extract_cookie_value(CookieHeader, <<"argocd.token">>) of
        {ok, Token} ->
            {ok, Token};
        error ->
            extract_cookie_value(CookieHeader, <<"argocd.token.v2">>)
    end;
extract_argocd_token_from_cookie(_) ->
    error.

extract_cookie_value(CookieHeader, Name) when is_binary(CookieHeader), is_binary(Name) ->
    Segments = binary:split(CookieHeader, <<";">>, [global]),
    extract_cookie_value_segments(Segments, string:lowercase(Name));
extract_cookie_value(_, _) ->
    error.

extract_cookie_value_segments([], _NameLower) ->
    error;
extract_cookie_value_segments([Seg | Rest], NameLower) ->
    Trimmed = string:trim(Seg),
    case binary:match(Trimmed, <<"=">>) of
        {Pos, 1} ->
            Key = string:lowercase(binary:part(Trimmed, 0, Pos)),
            ValPos = Pos + 1,
            ValLen = byte_size(Trimmed) - ValPos,
            Value =
                case ValLen > 0 of
                    true -> binary:part(Trimmed, ValPos, ValLen);
                    false -> <<>>
                end,
            case Key =:= NameLower of
                true -> {ok, Value};
                false -> extract_cookie_value_segments(Rest, NameLower)
            end;
        nomatch ->
            extract_cookie_value_segments(Rest, NameLower)
    end.

skip_forwarded_for(_Host, Path) when is_binary(Path) ->
    IsConsolePath =
        binary:match(Path, <<"/termproxy">>) =/= nomatch orelse
        binary:match(Path, <<"/vncproxy">>) =/= nomatch orelse
        binary:match(Path, <<"/vncwebsocket">>) =/= nomatch orelse
        binary:match(Path, <<"/websockify">>) =/= nomatch,
    IsConsolePath;
skip_forwarded_for(_, _) ->
    false.

version_to_bin('HTTP/1.0') -> <<"HTTP/1.0">>;
version_to_bin('HTTP/1.1') -> <<"HTTP/1.1">>;
version_to_bin('HTTP/2')   -> <<"HTTP/2">>;
version_to_bin(_)          -> <<"HTTP/1.1">>.

forwarded_proto(Req, InHeaders) ->
    case maps:get(<<"x-forwarded-proto">>, InHeaders, undefined) of
        <<"https">> -> <<"https">>;
        <<"http">> -> <<"http">>;
        <<"HTTPS">> -> <<"https">>;
        <<"HTTP">> -> <<"http">>;
        _ ->
            case cowboy_req:scheme(Req) of
                https -> <<"https">>;
                <<"https">> -> <<"https">>;
                _ -> <<"http">>
            end
    end.

maybe_restore_grpc_te_header(grpc, InHeaders, Filtered) ->
    case maps:get(<<"te">>, InHeaders, undefined) of
        <<"trailers">> -> Filtered#{<<"te">> => <<"trailers">>};
        <<"Trailers">> -> Filtered#{<<"te">> => <<"trailers">>};
        _ -> Filtered
    end;
maybe_restore_grpc_te_header(_, _InHeaders, Filtered) ->
    Filtered.

response_headers_to_req(Req, List) when is_list(List) ->
    {Req1, Filtered} = lists:foldl(
        fun({K, V}, {ReqAcc, HeadersAcc}) ->
            case lower_header_key(K) of
                <<"set-cookie">> ->
                    case cow_cookie:parse_set_cookie(iolist_to_binary(V)) of
                        {ok, Name, Value, Attrs} ->
                            Opts = cookie_attrs_to_opts(Attrs),
                            {cowboy_req:set_resp_cookie(Name, Value, ReqAcc, Opts), HeadersAcc};
                        ignore ->
                            {ReqAcc, HeadersAcc}
                    end;
                LowerK ->
                    case is_hop_by_hop_response_header(LowerK) of
                        true ->
                            {ReqAcc, HeadersAcc};
                        false ->
                            {ReqAcc, [{LowerK, V} | HeadersAcc]}
                    end
            end
        end,
        {Req, []},
        List
    ),
    Headers0 = maps:from_list(Filtered),
    Headers1 = rewrite_loopback_location(Req, Headers0),
    {Req1, Headers1}.

%% If the upstream returns an absolute Location pointing to a loopback address
%% (e.g. Harbor registry returns http://localhost:8099/v2/.../blobs/uploads/<uuid>
%% when relativeurls is not configured), rewrite it to the external scheme+host
%% of the original downstream request.  Without this, Docker follows the internal
%% URL and immediately gets EOF because localhost on the client is unreachable.
rewrite_loopback_location(Req, Headers) ->
    case maps:find(<<"location">>, Headers) of
        error -> Headers;
        {ok, Location} ->
            Headers#{<<"location">> => rewrite_loopback_location_url(Req, Location)}
    end.

rewrite_loopback_location_url(Req, Location) ->
    try
        case uri_string:parse(Location) of
            #{host := LocHost} = Parsed ->
                case is_loopback_host(LocHost) of
                    true ->
                        ExtHost = cowboy_req:host(Req),
                        %% The proxy always terminates TLS; use https regardless
                        %% of what the upstream returned internally.
                        Rewritten = maps:without([port], Parsed#{
                            scheme => <<"https">>,
                            host   => ExtHost
                        }),
                        iolist_to_binary(uri_string:recompose(Rewritten));
                    false ->
                        Location
                end;
            _ ->
                Location
        end
    catch _:_ ->
        Location
    end.

lower_header_key(K) when is_binary(K) ->
    string:lowercase(K);
lower_header_key(K) when is_list(K) ->
    list_to_binary(string:lowercase(K));
lower_header_key(K) ->
    iolist_to_binary(io_lib:format("~p", [K])).

is_hop_by_hop_response_header(<<"connection">>) -> true;
is_hop_by_hop_response_header(<<"keep-alive">>) -> true;
is_hop_by_hop_response_header(<<"proxy-authenticate">>) -> true;
is_hop_by_hop_response_header(<<"proxy-authorization">>) -> true;
is_hop_by_hop_response_header(<<"te">>) -> true;
is_hop_by_hop_response_header(<<"trailer">>) -> true;
is_hop_by_hop_response_header(<<"transfer-encoding">>) -> true;
is_hop_by_hop_response_header(<<"upgrade">>) -> true;
is_hop_by_hop_response_header(_) -> false.

%% cow_cookie:parse_set_cookie/1 returns 'max_age' as an absolute calendar
%% datetime, and may include 'expires'. cowboy_req:set_resp_cookie/4 expects
%% 'max_age' as a non-negative integer (seconds) and does not accept 'expires'.
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
    Host = cowboy_req:host(Req),
    case detect_request_kind(Req, Host) of
        grpc -> <<"grpc">>;
        _ -> cowboy_req_proto_metric(Req)
    end.

%% Path + header map variant for HTTP/3 gateway (no cowboy_req).
-spec upstream_req_kind(binary(), map()) -> http | eventstream | grpc.
upstream_req_kind(Path, HeadersMap) ->
    upstream_req_kind(Path, HeadersMap, undefined).

-spec upstream_req_kind(binary(), map(), binary() | undefined) -> http | eventstream | grpc.
upstream_req_kind(Path, HeadersMap, SiteHost) when is_binary(Path), is_map(HeadersMap) ->
    case site_backend_grpc_upstream(SiteHost) of
        true ->
            case is_grpc_headers_map(HeadersMap) orelse is_connect_service_path(Path) of
                true -> grpc;
                false -> http
            end;
        false ->
            case is_sse_proxy_request(Path, HeadersMap) of
                true ->
                    eventstream;
                false ->
                    case should_use_mixed_grpc_compat_http(Path, SiteHost) of
                        true -> http;
                        false ->
                            case is_grpc_headers_map(HeadersMap) orelse is_connect_service_path(Path) of
                                true -> grpc;
                                false -> http
                            end
                    end
            end
    end;
upstream_req_kind(_Path, _HeadersMap, _SiteHost) ->
    http.

is_grpc_headers_map(HMap) ->
    Ct = string:lowercase(maps:get(<<"content-type">>, HMap, <<>>)),
    case Ct of
        <<"application/grpc", _/binary>> -> true;
        <<"application/grpc-web", _/binary>> -> true;
        <<"application/connect+", _/binary>> -> true;
        _ ->
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
                maps:keys(HMap)
            )
    end.

detect_request_kind(Req, SiteHost) ->
    case site_backend_grpc_upstream(SiteHost) of
        true ->
            %% grpc_upstream means the backend supports gRPC, but do not force every
            %% request to gRPC. Harbor-style REST endpoints on the same host should
            %% remain plain HTTP unless request signals gRPC semantics.
            Path0 = cowboy_req:path(Req),
            case is_grpc_request(Req) orelse is_connect_service_path(Path0) of
                true -> grpc;
                false -> http
            end;
        false ->
            Path = cowboy_req:path(Req),
            case is_event_stream_request(Req) orelse is_stream_endpoint_request(Req) of
                true ->
                    %% EventSource/watch endpoints are client-facing HTTP streams.
                    %% Route them through the HTTP streaming path and prefer upstream
                    %% HTTP/1.1 for compatibility with long-lived SSE streams.
                    eventstream;
                false ->
                    case is_websocket_upgrade(Req) of
                        true -> websocket;
                        false ->
                            case should_use_mixed_grpc_compat_http(Path, SiteHost) of
                                true -> http;
                                false ->
                                    case is_grpc_request(Req) orelse is_connect_service_path(Path) of
                                        true -> grpc;
                                        false -> http
                                    end
                            end
                    end
            end
    end.

should_use_mixed_grpc_compat_http(Path, SiteHost) when is_binary(Path) ->
    is_binary(SiteHost)
        andalso SiteHost =/= <<>>
        andalso is_connect_service_path(Path)
        andalso binary:match(Path, <<"/api/">>) =:= {0, byte_size(<<"/api/">>)};
should_use_mixed_grpc_compat_http(_Path, _SiteHost) ->
    false.

%% Connect / gRPC service paths (Talos Omni, Connect RPC): /api/pkg.Service/Method.
-spec is_connect_service_path(binary()) -> boolean().
is_connect_service_path(Path) when is_binary(Path) ->
    connect_service_path_suffix(Path);
is_connect_service_path(_) ->
    false.

connect_service_path_suffix(<<"/api/", Rest/binary>>) ->
    connect_service_path_has_dot_service(Rest);
connect_service_path_suffix(Path) ->
    connect_service_path_has_dot_service(Path).

connect_service_path_has_dot_service(Bin) ->
    case binary:match(Bin, <<".">>) of
        nomatch ->
            false;
        _ ->
            case binary:match(Bin, <<"/">>) of
                {Pos, _} when Pos > 0 ->
                    ServicePart = binary:part(Bin, 0, Pos),
                    binary:match(ServicePart, <<".">>) =/= nomatch
                        andalso not looks_like_version_segment(ServicePart);
                _ ->
                    false
            end
    end.

%% Avoid false-positive matching for REST paths like "/api/v2.0/systeminfo".
looks_like_version_segment(<<"v", Rest/binary>>) ->
    Rest =/= <<>> andalso all_digits_or_dot(Rest);
looks_like_version_segment(_) ->
    false.

all_digits_or_dot(<<>>) ->
    true;
all_digits_or_dot(<<C, Rest/binary>>) when (C >= $0 andalso C =< $9) orelse C =:= $. ->
    all_digits_or_dot(Rest);
all_digits_or_dot(_) ->
    false.

site_backend_grpc_upstream(SiteHost) when is_binary(SiteHost), SiteHost =/= <<>> ->
    Config = pertisk_eproxy_config:get_config(),
    Sites = maps:get(sites, Config, []),
    case find_site_for_host(Sites, normalize_host(SiteHost)) of
        undefined ->
            false;
        #{backend := BackendName} ->
            case pertisk_eproxy_config:get_backend(BackendName) of
                {ok, #{grpc_upstream := true}} -> true;
                _ -> false
            end
    end;
site_backend_grpc_upstream(_) ->
    false.

is_grpc_request(Req) ->
    Ct = cowboy_req:header(<<"content-type">>, Req, <<>>),
    CtLower = string:lowercase(Ct),
    case CtLower of
        <<"application/grpc", _/binary>> -> true;
        <<"application/grpc-web", _/binary>> -> true;
        <<"application/connect+", _/binary>> -> true;
        _ ->
            %% Connect RPCs frequently use HTTP/1.1 and content-types like
            %% application/proto or application/json with explicit Connect headers.
            case has_connect_rpc_headers(Req) of
                true -> true;
                false ->
                    %% Avoid matching on TE alone; use grpc-specific metadata hints only.
                    has_grpc_metadata_headers(Req)
            end
    end.

has_connect_rpc_headers(Req) ->
    Hdrs = cowboy_req:headers(Req),
    maps:is_key(<<"connect-protocol-version">>, Hdrs)
        orelse maps:is_key(<<"connect-timeout-ms">>, Hdrs)
        orelse maps:is_key(<<"grpc-encoding">>, Hdrs)
        orelse maps:is_key(<<"grpc-accept-encoding">>, Hdrs)
        orelse maps:is_key(<<"grpc-status-details-bin">>, Hdrs).

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

gun_protocols_for_request(grpc, _Transport) ->
    %% gRPC requires HTTP/2 transport semantics.
    [http2];
gun_protocols_for_request(eventstream, Transport) ->
    gun_protocols_for_eventstream(Transport);
gun_protocols_for_request(_, tls) ->
    %% Prefer HTTP/2 when upstream TLS endpoint supports ALPN; keep HTTP/1 fallback.
    [http2, http];
gun_protocols_for_request(_, _) ->
    [http].

gun_protocols_for_request(grpc, _Transport, _UpPort) ->
    [http2];
gun_protocols_for_request(eventstream, Transport, _UpPort) ->
    gun_protocols_for_eventstream(Transport);
gun_protocols_for_request(_, _Transport, 8006) ->
    %% Proxmox API/noVNC traffic is sensitive to upstream stream reuse; force HTTP/1.
    [http];
gun_protocols_for_request(ReqKind, Transport, _UpPort) ->
    gun_protocols_for_request(ReqKind, Transport).

%% @doc gun protocol list for long-lived SSE/watch upstream connections.
%% Plain TCP gun connections only accept a single protocol (see gun.erl connecting/3).
-spec gun_protocols_for_eventstream(tcp | tls | term()) -> [atom()].
gun_protocols_for_eventstream(tls) ->
    [http2, http];
gun_protocols_for_eventstream(tcp) ->
    %% Plain TCP backends (e.g. Gitea /user/events) use HTTP/1.1 SSE.
    [http];
gun_protocols_for_eventstream(_) ->
    [http].

%% @doc Candidate upstream targets for long-lived SSE/watch streams.
-spec eventstream_upstream_candidates(
    term(), non_neg_integer(), tcp | tls | term(), binary()
) -> [map()].
eventstream_upstream_candidates(UpHost, UpPort, Transport, _Path) ->
    [eventstream_upstream_candidate(UpHost, UpPort, Transport, gun_protocols_for_eventstream(Transport))].

eventstream_upstream_candidate(UpHost, UpPort, Transport, Protocols) ->
    #{
        host => UpHost,
        port => UpPort,
        transport => Transport,
        protocols => Protocols
    }.

-spec upstream_gun_opts_eventstream(map()) -> map().
upstream_gun_opts_eventstream(#{host := UpHost, transport := Transport, protocols := Protocols}) ->
    Base = #{
        transport => Transport,
        protocols => Protocols,
        connect_timeout => ?CONNECT_TIMEOUT,
        tcp_opts => [{keepalive, true}, {nodelay, true}]
    },
    Base1 =
        case lists:member(http2, Protocols) of
            true ->
                Base#{
                    http2_opts => #{
                        keepalive => ?GRPC_HTTP2_KEEPALIVE_MS,
                        keepalive_tolerance => ?GRPC_HTTP2_KEEPALIVE_TOLERANCE
                    }
                };
            false ->
                Base
        end,
    case Transport of
        tls ->
            Base1#{tls_opts => upstream_tls_opts(UpHost)};
        _ ->
            Base1
    end.

-spec eventstream_initial_await_timeout_ms(map()) -> timeout().
eventstream_initial_await_timeout_ms(_Candidate) ->
    sse_initial_headers_timeout_ms().

-spec eventstream_upstream_retryable(term()) -> boolean().
eventstream_upstream_retryable({await_up, _}) -> true;
eventstream_upstream_retryable({connect, _}) -> true;
eventstream_upstream_retryable({stream_error, closed}) -> true;
eventstream_upstream_retryable({stream_error, _}) -> true;
eventstream_upstream_retryable(timeout) -> true;
eventstream_upstream_retryable({timeout, _}) -> true;
eventstream_upstream_retryable({await_response_unexpected, _}) -> true;
eventstream_upstream_retryable(_) -> false.

%% @doc Try SSE upstream candidates until one connects and proxies successfully.
-spec with_eventstream_upstream(
    fun((pid(), map()) -> term()), term(), non_neg_integer(), tcp | tls | term(), binary()
) -> term().
with_eventstream_upstream(Fun, UpHost0, UpPort0, Transport0, Path) ->
    Candidates = eventstream_upstream_candidates(UpHost0, UpPort0, Transport0, Path),
    with_eventstream_upstream_candidates(Fun, Candidates).

with_eventstream_upstream_candidates(_Fun, []) ->
    {error, all_eventstream_upstreams_failed};
with_eventstream_upstream_candidates(Fun, [Candidate | Rest]) ->
    #{host := H, port := P} = Candidate,
    GunOpts = upstream_gun_opts_eventstream(Candidate),
    Candidate1 = Candidate#{gun_opts => GunOpts},
    case open_direct_connection(H, P, GunOpts) of
        {error, ConnectReason} ->
            case Rest =/= [] andalso eventstream_upstream_retryable(ConnectReason) of
                true ->
                    lager:debug(
                        "eventstream upstream connect ~s:~p failed ~p, trying next",
                        [H, P, ConnectReason]
                    ),
                    with_eventstream_upstream_candidates(Fun, Rest);
                false ->
                    {error, ConnectReason}
            end;
        {ok, ConnPid} ->
            try
                case Fun(ConnPid, Candidate1) of
                    {error, ProxyReason} = Err ->
                        case Rest =/= [] andalso eventstream_upstream_retryable(ProxyReason) of
                            true ->
                                lager:debug(
                                    "eventstream upstream ~s:~p failed ~p, trying next",
                                    [H, P, ProxyReason]
                                ),
                                with_eventstream_upstream_candidates(Fun, Rest);
                            false ->
                                Err
                        end;
                    Ok ->
                        Ok
                end
            after
                catch gun:close(ConnPid)
            end
    end.

sse_initial_headers_timeout_ms() ->
    Config = pertisk_eproxy_config:get_config(),
    case maps:get(sse_initial_headers_timeout_ms, Config, ?DEFAULT_SSE_INITIAL_HEADERS_MS) of
        N when is_integer(N), N > 0 -> N;
        _ -> ?DEFAULT_SSE_INITIAL_HEADERS_MS
    end.

sse_early_flush_enabled() ->
    Config = pertisk_eproxy_config:get_config(),
    case maps:get(sse_early_flush_enabled, Config, true) of
        false -> false;
        _ -> true
    end.

%% @doc True when an authenticated SSE request should flush ': connected' before
%% upstream response headers (idle watch APIs such as Argo CD).
-spec should_sse_early_flush(binary(), binary(), map() | [{binary(), binary()}]) -> boolean().
should_sse_early_flush(Host, Path, Headers) when is_binary(Host), is_binary(Path) ->
    headers_have_sse_auth(Headers) andalso resolve_sse_early_flush(Host, Path);
should_sse_early_flush(_, _, _) ->
    false.

resolve_sse_early_flush(Host, Path) ->
    Override = sse_early_flush_override(Host, Path),
    case sse_early_flush_enabled() of
        true ->
            case Override of
                false -> false;
                _ -> true
            end;
        false ->
            Override =:= true
    end.

sse_early_flush_override(Host, Path) ->
    case pertisk_eproxy_router:route(Host, Path) of
        {ok, #{sse_early_flush := Setting}} when Setting =:= true; Setting =:= false ->
            Setting;
        {ok, _} ->
            site_sse_early_flush_setting(Host);
        {error, no_route} ->
            site_sse_early_flush_setting(Host)
    end.

site_sse_early_flush_setting(Host) ->
    Config = pertisk_eproxy_config:get_config(),
    Sites = maps:get(sites, Config, []),
    case find_site_for_host(Sites, normalize_host(Host)) of
        undefined -> undefined;
        Site -> maps:get(sse_early_flush, Site, undefined)
    end.

%% Any non-empty Authorization or Cookie header (not app-specific).
-spec headers_have_sse_auth(map() | [{binary(), binary()}]) -> boolean().
headers_have_sse_auth(Headers) when is_map(Headers) ->
    case maps:get(<<"authorization">>, Headers, undefined) of
        Auth when is_binary(Auth), byte_size(Auth) > 0 ->
            true;
        _ ->
            case maps:get(<<"cookie">>, Headers, undefined) of
                Cookie when is_binary(Cookie), byte_size(Cookie) > 0 ->
                    true;
                _ ->
                    false
            end
    end;
headers_have_sse_auth(Headers) when is_list(Headers) ->
    headers_have_sse_auth(maps:from_list(Headers));
headers_have_sse_auth(_) ->
    false.

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

with_tracking_id_header(_TrackingId, Headers) when is_map(Headers) ->
    Headers.

request_tracking_id(Req) ->
    case cowboy_req:header(<<"x-request-id">>, Req, <<>>) of
        <<>> -> generate_tracking_id();
        Existing -> Existing
    end.

generate_tracking_id() ->
    integer_to_binary(erlang:unique_integer([positive, monotonic])).

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

%% Whether the HTTP/3 listener should serve traffic for this host.
%% Unknown hosts stay enabled (404/no-route path); explicit advertise_http3=false opts out.
site_http3_enabled(Host) ->
    Config = pertisk_eproxy_config:get_config(),
    Sites = maps:get(sites, Config, []),
    case find_site_for_host(Sites, normalize_host(Host)) of
        undefined -> true;
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

request_timeout_ms(Req, ReqKind, _Host, UpHost) ->
    Config = pertisk_eproxy_config:get_config(),
    GlobalTimeout = case maps:get(upstream_request_timeout_ms, Config, ?DEFAULT_REQUEST_TIMEOUT_MS) of
        GN when is_integer(GN), GN > 0 -> GN;
        _ -> ?DEFAULT_REQUEST_TIMEOUT_MS
    end,
    case is_event_stream_request(Req) orelse is_stream_endpoint_request(Req) of
        true ->
            %% EventSource/watch requests are long-lived by design.
            %% Stream timeout is configurable; defaults to infinity.
            stream_request_timeout(Config, GlobalTimeout);
        false ->
            case ReqKind =/= grpc andalso is_loopback_host(UpHost) andalso not loopback_pool_enabled() of
                true ->
                    LoopbackTimeout = case maps:get(upstream_loopback_request_timeout_ms,
                                                    Config,
                                                    ?DEFAULT_LOOPBACK_REQUEST_TIMEOUT_MS) of
                        LN when is_integer(LN), LN > 0 -> LN;
                        _ -> ?DEFAULT_LOOPBACK_REQUEST_TIMEOUT_MS
                    end,
                    min(GlobalTimeout, LoopbackTimeout);
                false ->
                    GlobalTimeout
            end
    end.

stream_request_timeout(Config, GlobalTimeout) when is_map(Config) ->
    case maps:get(upstream_stream_request_timeout_ms, Config, 120000) of
        infinity -> infinity;
        <<"infinity">> -> infinity;
        N when is_integer(N), N > 0 -> N;
        _ -> min(GlobalTimeout, 120000)
    end;
stream_request_timeout(_, GlobalTimeout) ->
    GlobalTimeout.

is_event_stream_request(Req) ->
    is_event_stream_accept(cowboy_req:header(<<"accept">>, Req, <<>>)).

is_stream_endpoint_request(Req) ->
    is_sse_proxy_path(cowboy_req:path(Req)).

is_event_stream_accept(Accept) when is_binary(Accept) ->
    binary:match(string:lowercase(Accept), <<"text/event-stream">>) =/= nomatch;
is_event_stream_accept(_) ->
    false.

is_sse_proxy_request(Path, Headers) when is_binary(Path), is_map(Headers) ->
    is_event_stream_accept(maps:get(<<"accept">>, Headers, <<>>))
        orelse is_sse_proxy_path(Path);
is_sse_proxy_request(Path, _Headers) when is_binary(Path) ->
    is_sse_proxy_path(Path);
is_sse_proxy_request(_, _) ->
    false.

is_sse_proxy_path(ReqPath) ->
    is_stream_endpoint_path(ReqPath)
        orelse is_gitea_events_path(ReqPath).

is_stream_endpoint_path(ReqPath) ->
    case ReqPath of
        Bin when is_binary(Bin) ->
            binary:match(Bin, <<"/api/v1/stream/">>) =/= nomatch;
        _ ->
            false
    end.

is_gitea_events_path(<<"/user/events", _/binary>>) ->
    true;
is_gitea_events_path(_) ->
    false.
