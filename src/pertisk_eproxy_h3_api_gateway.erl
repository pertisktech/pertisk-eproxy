%% @doc HTTP/3 gateway to the management listener (SPA + /api/*), same as TCP :9080.
-module(pertisk_eproxy_h3_api_gateway).

-export([start/1, stop/0, start_probe/1, stop_probe/0, handle_request/5]).

-define(SERVER, pertisk_eproxy_h3_api).
-define(PROBE_SERVER, pertisk_eproxy_h3_probe).
-define(BODY_TIMEOUT, 15000).

start(Config) ->
    _ = ensure_quic_started(),
    Port = case maps:get(quic_port, Config, undefined) of
        P when is_integer(P), P > 0 -> P;
        _ -> maps:get(https_port, Config, 443)
    end,
    {CertDer, KeyTerm} = load_cert_and_key(Config),
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
    BasePort = case maps:get(quic_port, Config, undefined) of
        P when is_integer(P), P > 0 -> P;
        _ -> maps:get(https_port, Config, 443)
    end,
    ProbePort = maps:get(h3_probe_port, Config, BasePort + 1),
    {CertDer, KeyTerm} = load_cert_and_key(Config),
    ProbeOpts = #{
        cert => CertDer,
        key => KeyTerm,
        handler => pertisk_eproxy_h3_probe_handler
    },
    start_prefer_ipv6_server(?PROBE_SERVER, ProbePort, ProbeOpts).

stop_probe() ->
    catch quic_h3:stop_server(?PROBE_SERVER),
    ok.

handle_request(Conn, StreamId, Method, Path, Headers) ->
    _ = ensure_inets_started(),
    T0 = erlang:monotonic_time(millisecond),
    Host = authority_host(Headers),
    try
        Body = read_request_body(Conn, StreamId, Method),
        case proxy_to_admin(Method, Path, Headers, Body) of
            {ok, Status, RespHeaders, RespBody} ->
                ok = quic_h3:send_response(Conn, StreamId, Status, RespHeaders),
                _ = quic_h3:send_data(Conn, StreamId, RespBody, true),
                log_h3_access(Host, Method, Path, Status, T0),
                ok;
            {error, ProxyReason} ->
                lager:warning("h3 proxy_to_admin failed: ~p host=~s path=~s", [
                    ProxyReason, Host, Path
                ]),
                ok = quic_h3:send_response(
                    Conn, StreamId, 502, [{<<"content-type">>, <<"text/plain">>}]
                ),
                _ = quic_h3:send_data(Conn, StreamId, <<"Bad Gateway">>, true),
                log_h3_access(Host, Method, Path, 502, T0),
                ok
        end
    catch
        Class:Reason:Stack ->
            lager:error(
                "h3 handle_request crash class=~p reason=~p host=~s path=~s stack=~p",
                [Class, Reason, Host, Path, Stack]
            ),
            _ = catch quic_h3:send_response(
                Conn, StreamId, 500, [{<<"content-type">>, <<"text/plain">>}]
            ),
            _ = catch quic_h3:send_data(Conn, StreamId, <<"Internal Server Error">>, true),
            log_h3_access(Host, Method, Path, 500, T0),
            ok
    end.

authority_host(Headers) ->
    case lists:keyfind(<<":authority">>, 1, Headers) of
        {_, V} when is_binary(V) -> V;
        _ -> <<"-">>
    end.

log_h3_access(Host, Method, Path, Status, T0) ->
    Dt = max(0, erlang:monotonic_time(millisecond) - T0),
    catch pertisk_eproxy_access_log:log_proxy(Host, Method, Path, Status, Dt, 'HTTP/3').

read_request_body(_Conn, _StreamId, <<"GET">>) -> <<>>;
read_request_body(_Conn, _StreamId, <<"HEAD">>) -> <<>>;
read_request_body(Conn, StreamId, _Method) ->
    case quic_h3:set_stream_handler(Conn, StreamId, self()) of
        {ok, Buffered} ->
            collect_body(Conn, StreamId, chunks_to_binary(Buffered));
        ok ->
            collect_body(Conn, StreamId, <<>>);
        _ ->
            <<>>
    end.

chunks_to_binary(Chunks) ->
    iolist_to_binary([D || {D, _Fin} <- Chunks]).

collect_body(Conn, StreamId, Acc) ->
    receive
        {quic_h3, Conn, {data, StreamId, Data, true}} ->
            <<Acc/binary, Data/binary>>;
        {quic_h3, Conn, {data, StreamId, Data, false}} ->
            collect_body(Conn, StreamId, <<Acc/binary, Data/binary>>)
    after ?BODY_TIMEOUT ->
        Acc
    end.

proxy_to_admin(MethodBin, Path, Headers, Body) ->
    Method = method_to_httpc(MethodBin),
    Url = <<"http://127.0.0.1:9080", Path/binary>>,
    ReqHeaders0 = h3_headers_to_httpc(Headers),
    ReqHeaders = ensure_http_host_header(Headers, ReqHeaders0),
    case Method of
        get ->
            case httpc:request(get, {binary_to_list(Url), ReqHeaders}, [{timeout, 15000}], [{body_format, binary}]) of
                {ok, {{_Vsn, Status, _Reason}, RespHeaders, RespBody}} ->
                    {ok, Status, httpc_headers_to_h3(RespHeaders), iolist_to_binary(RespBody)};
                Error ->
                    {error, Error}
            end;
        head ->
            case httpc:request(head, {binary_to_list(Url), ReqHeaders}, [{timeout, 15000}], [{body_format, binary}]) of
                {ok, {{_Vsn, Status, _Reason}, RespHeaders, RespBody}} ->
                    {ok, Status, httpc_headers_to_h3(RespHeaders), iolist_to_binary(RespBody)};
                Error ->
                    {error, Error}
            end;
        _ ->
            ContentType = proplists:get_value("content-type", ReqHeaders, "application/octet-stream"),
            Request = {binary_to_list(Url), ReqHeaders, ContentType, Body},
            case httpc:request(Method, Request, [{timeout, 15000}], [{body_format, binary}]) of
                {ok, {{_Vsn, Status, _Reason}, RespHeaders, RespBody}} ->
                    {ok, Status, httpc_headers_to_h3(RespHeaders), iolist_to_binary(RespBody)};
                Error ->
                    {error, Error}
            end
    end.

method_to_httpc(<<"GET">>) -> get;
method_to_httpc(<<"POST">>) -> post;
method_to_httpc(<<"PUT">>) -> put;
method_to_httpc(<<"PATCH">>) -> patch;
method_to_httpc(<<"DELETE">>) -> delete;
method_to_httpc(<<"HEAD">>) -> head;
method_to_httpc(<<"OPTIONS">>) -> options;
method_to_httpc(_) -> get.

h3_headers_to_httpc(Headers) ->
    [
        {string:lowercase(binary_to_list(K)), binary_to_list(V)}
        || {K, V} <- Headers,
           is_binary(K),
           is_binary(V),
           byte_size(K) > 0,
           binary:at(K, 0) =/= $:
    ].

ensure_http_host_header(H3Headers, ReqHeaders) ->
    HasHost = lists:any(
        fun({K, _}) -> string:equal(K, "host", true) end,
        ReqHeaders
    ),
    case HasHost of
        true ->
            ReqHeaders;
        false ->
            case lists:keyfind(<<":authority">>, 1, H3Headers) of
                {_, Auth} when is_binary(Auth) ->
                    [{"host", binary_to_list(Auth)} | ReqHeaders];
                _ ->
                    [{"host", "127.0.0.1"} | ReqHeaders]
            end
    end.

httpc_headers_to_h3(Headers) ->
    %% Keep only end-to-end headers that are safe for H3 forwarding.
    %% Drop hop-by-hop headers and origin-server generated transport metadata.
    Blocked = [
        "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
        "te", "trailers", "transfer-encoding", "upgrade",
        "date", "server", "content-length"
    ],
    [
        {list_to_binary(string:lowercase(K)), list_to_binary(V)}
        || {K, V} <- Headers,
           not lists:member(string:lowercase(K), Blocked)
    ].

ensure_inets_started() ->
    case application:ensure_all_started(inets) of
        {ok, _} -> ok;
        {error, {already_started, inets}} -> ok;
        _ -> ok
    end.

ensure_quic_started() ->
    _ = application:ensure_all_started(quic),
    _ = application:ensure_all_started(quicer),
    ok.

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
    {ok, CertPem} = file:read_file(CertPath),
    {ok, KeyPem} = file:read_file(KeyPath),
    [CertEntry | _] = public_key:pem_decode(CertPem),
    [KeyEntry | _] = public_key:pem_decode(KeyPem),
    {element(2, CertEntry), public_key:pem_entry_decode(KeyEntry)}.
