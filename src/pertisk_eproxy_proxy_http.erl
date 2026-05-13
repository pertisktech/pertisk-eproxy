%% @doc HTTP/1.1 reverse proxy (Gun upstream), Ranch request map.
-module(pertisk_eproxy_proxy_http).

-export([handle/1, parse_upstream/1, alt_svc_advertised_port/1]).

-define(REQUEST_TIMEOUT, 60000).
-define(CONNECT_TIMEOUT, 10000).

-spec handle(pertisk_req:req()) -> {reply, pos_integer(), #{binary() => binary()}, binary()}.
handle(Req) ->
    Method = pertisk_req:method(Req),
    Host = pertisk_req:route_host(Req),
    Path = pertisk_req:path(Req),
    Qs = pertisk_req:qs(Req),
    Scheme = pertisk_req:scheme(Req),
    FwdProto = forwarded_proto_bin(Scheme),
    Proto = proto_metric(Scheme),
    Vsn = http_version_bin(Req),
    T0 = erlang:monotonic_time(millisecond),
    case pertisk_eproxy_router:route(Host, Path) of
        {error, no_route} ->
            pertisk_eproxy_metrics:inc_request(Host, <<"404">>, Proto),
            H404 = maybe_add_alt_svc(Req, Host,
                pertisk_eproxy_security_headers:merge_response_headers(Host,
                    #{<<"content-type">> => <<"text/plain">>}, FwdProto)),
            log_access(Host, Method, Path, 404, T0, Vsn, <<>>),
            {reply, 404, H404, <<"No route found for host: ", Host/binary>>};
        {ok, #{upstream_path := UpstreamPath, backend := BackendName}} ->
            ClientIp = client_ip(Req),
            case pertisk_eproxy_backend:pick_upstream(BackendName, ClientIp) of
                {error, no_healthy_upstream} ->
                    pertisk_eproxy_metrics:inc_request(Host, <<"502">>, Proto),
                    H502 = maybe_add_alt_svc(Req, Host,
                        pertisk_eproxy_security_headers:merge_response_headers(Host,
                            #{<<"content-type">> => <<"text/plain">>}, FwdProto)),
                    log_access(Host, Method, Path, 502, T0, Vsn, <<>>),
                    {reply, 502, H502, <<"Bad Gateway: no healthy upstream">>};
                {ok, UpstreamAddr} ->
                    case proxy_request(Req, Method, Host, UpstreamPath, Qs, UpstreamAddr, ClientIp) of
                        {ok, StatusCode, RespHeaders, RespBody} ->
                            StatusBin = integer_to_binary(StatusCode),
                            pertisk_eproxy_metrics:inc_request(Host, StatusBin, Proto),
                            pertisk_eproxy_backend:done_upstream(BackendName, UpstreamAddr, ok),
                            log_access(Host, Method, Path, StatusCode, T0, Vsn, UpstreamAddr),
                            {reply, StatusCode, RespHeaders, RespBody};
                        {error, Reason} ->
                            pertisk_eproxy_metrics:inc_request(Host, <<"502">>, Proto),
                            pertisk_eproxy_backend:done_upstream(BackendName, UpstreamAddr, error),
                            lager:warning("Proxy error ~p for ~s~s -> ~s",
                                [Reason, Host, Path, UpstreamAddr]),
                            H502 = maybe_add_alt_svc(Req, Host,
                                pertisk_eproxy_security_headers:merge_response_headers(Host,
                                    #{<<"content-type">> => <<"text/plain">>}, FwdProto)),
                            log_access(Host, Method, Path, 502, T0, Vsn, UpstreamAddr),
                            {reply, 502, H502, <<"Bad Gateway">>}
                    end
            end
    end.

proto_metric(https) -> <<"tls_h1">>;
proto_metric(http) -> <<"http1">>.

forwarded_proto_bin(https) -> <<"https">>;
forwarded_proto_bin(http) -> <<"http">>.

http_version_bin(Req) ->
    case pertisk_req:http_version(Req) of
        <<"HTTP/1.0">> -> 'HTTP/1.0';
        _ -> 'HTTP/1.1'
    end.

log_access(Host, Method, Path, Status, T0, Vsn, Upstream) ->
    Dt = max(0, erlang:monotonic_time(millisecond) - T0),
    catch pertisk_eproxy_access_log:log_proxy(Host, Method, Path, Status, Dt, Vsn, Upstream).

proxy_request(Req, Method, Host, UpstreamPath, Qs, UpstreamAddr, ClientIp) ->
    {UpHost, UpPort, Transport} = parse_upstream(UpstreamAddr),
    FullPath = case Qs of
        <<>> -> UpstreamPath;
        _ -> <<UpstreamPath/binary, "?", Qs/binary>>
    end,
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
                    Res = do_proxy(Req, ConnPid, Method, Host, FullPath, ClientIp),
                    gun:close(ConnPid),
                    Res
            end
    end.

do_proxy(Req, ConnPid, Method, Host, FullPath, ClientIp) ->
    Scheme = pertisk_req:scheme(Req),
    FwdProto = forwarded_proto_bin(Scheme),
    HeadersMap = forward_headers(Req, Host, ClientIp),
    Headers = maps:to_list(HeadersMap),
    Body = pertisk_req:body(Req),
    GunMethod = method_to_gun(Method),
    StreamRef = gun:request(ConnPid, GunMethod, FullPath, Headers, Body),
    case gun:await(ConnPid, StreamRef, ?REQUEST_TIMEOUT) of
        {response, nofin, Status, RespHeaders} ->
            {ok, RespBody} = gun:await_body(ConnPid, StreamRef, ?REQUEST_TIMEOUT),
            RespBin = iolist_to_binary(RespBody),
            ok = pertisk_eproxy_metrics:record_proxy_bytes(Host, byte_size(Body), byte_size(RespBin)),
            RawHeaders = headers_to_map(RespHeaders),
            SecHeaders = pertisk_eproxy_security_headers:merge_response_headers(Host, RawHeaders, FwdProto),
            OutHdrs = maybe_add_alt_svc(Req, Host, SecHeaders),
            {ok, Status, OutHdrs, RespBin};
        {response, fin, Status, RespHeaders} ->
            ok = pertisk_eproxy_metrics:record_proxy_bytes(Host, byte_size(Body), 0),
            RawHeaders = headers_to_map(RespHeaders),
            SecHeaders = pertisk_eproxy_security_headers:merge_response_headers(Host, RawHeaders, FwdProto),
            OutHdrs = maybe_add_alt_svc(Req, Host, SecHeaders),
            {ok, Status, OutHdrs, <<>>};
        {error, Reason} ->
            {error, Reason}
    end.

forward_headers(Req, OrigHost, ClientIp) ->
    InHeaders = pertisk_req:headers(Req),
    Proto = forwarded_proto_bin(pertisk_req:scheme(Req)),
    ProtoVsn = version_to_bin(pertisk_req:http_version(Req)),
    Filtered = maps:without(
        [<<"connection">>, <<"keep-alive">>, <<"te">>, <<"trailers">>, <<"transfer-encoding">>, <<"upgrade">>],
        InHeaders
    ),
    Base = Filtered#{
        <<"host">> => OrigHost,
        <<"x-forwarded-proto">> => Proto,
        <<"x-forwarded-proto-version">> => ProtoVsn
    },
    XFF = case maps:find(<<"x-forwarded-for">>, Base) of
        {ok, Existing} -> <<Existing/binary, ", ", ClientIp/binary>>;
        error -> ClientIp
    end,
    Base#{<<"x-forwarded-for">> => XFF}.

version_to_bin(<<"HTTP/1.0">>) -> <<"HTTP/1.0">>;
version_to_bin(<<"HTTP/1.1">>) -> <<"HTTP/1.1">>;
version_to_bin(_) -> <<"HTTP/1.1">>.

headers_to_map(List) ->
    HopByHop = [<<"connection">>, <<"keep-alive">>, <<"proxy-authenticate">>,
        <<"proxy-authorization">>, <<"te">>, <<"trailers">>, <<"transfer-encoding">>, <<"upgrade">>],
    Filtered = [{K, V} || {K, V} <- List, not lists:member(string:lowercase(K), HopByHop)],
    maps:from_list(Filtered).

client_ip(Req) ->
    case pertisk_req:header(Req, <<"x-forwarded-for">>) of
        undefined ->
            {PeerIp, _} = pertisk_req:peer(Req),
            list_to_binary(inet:ntoa(PeerIp));
        XFF ->
            hd(binary:split(XFF, [<<", ">>, <<",">>]))
    end.

parse_upstream(Addr) when is_binary(Addr) ->
    parse_upstream(binary_to_list(Addr));
parse_upstream("https://" ++ Rest) ->
    {Host, Port} = split_host_port(Rest, 443),
    {Host, Port, tls};
parse_upstream("http://" ++ Rest) ->
    {Host, Port} = split_host_port(Rest, 80),
    {Host, Port, tcp};
parse_upstream(Addr) ->
    {Host, Port} = split_host_port(Addr, 80),
    {Host, Port, tcp}.

split_host_port(Addr, DefaultPort) ->
    case string:split(Addr, ":", trailing) of
        [Host, PortStr] ->
            {Host, list_to_integer(string:trim(PortStr, trailing, "/"))};
        [Host] ->
            {Host, DefaultPort}
    end.

method_to_gun(<<"GET">>) -> <<"GET">>;
method_to_gun(<<"POST">>) -> <<"POST">>;
method_to_gun(<<"PUT">>) -> <<"PUT">>;
method_to_gun(<<"PATCH">>) -> <<"PATCH">>;
method_to_gun(<<"DELETE">>) -> <<"DELETE">>;
method_to_gun(<<"HEAD">>) -> <<"HEAD">>;
method_to_gun(<<"OPTIONS">>) -> <<"OPTIONS">>;
method_to_gun(M) -> M.

maybe_add_alt_svc(Req, Host, Headers) ->
    Scheme = pertisk_req:scheme(Req),
    Https = Scheme =:= https orelse Scheme =:= <<"https">>,
    Port = alt_svc_advertised_port(Req),
    case {Https, Port, pertisk_eproxy_handler:site_advertise_http3(Host)} of
        {true, P, true} when is_integer(P), P > 0 ->
            Headers#{<<"alt-svc">> => pertisk_h3_alt_svc:header_value(P)};
        _ ->
            Headers
    end.

-spec alt_svc_advertised_port(pertisk_req:req()) -> pos_integer() | undefined.
alt_svc_advertised_port(Req) ->
    Cfg = pertisk_eproxy_config:get_config(),
    pertisk_h3_alt_svc:advertised_port(Cfg, pertisk_req:port(Req)).
