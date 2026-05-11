%% @doc HTTP/3 API gateway using erlang_quic/quic_h3.
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
    error_logger:info_msg(
        "h3 request method=~p path=~p stream=~p~n",
        [Method, Path, StreamId]
    ),
    try
        case is_api_path(Path) of
            true ->
                Body = read_request_body(Conn, StreamId, Method),
                case proxy_to_admin(Method, Path, Headers, Body) of
                    {ok, Status, RespHeaders, RespBody} ->
                        error_logger:info_msg(
                            "h3 proxy success status=~p headers_count=~p body_bytes=~p~n",
                            [Status, length(RespHeaders), byte_size(RespBody)]
                        ),
                        error_logger:info_msg("h3 response headers=~p~n", [RespHeaders]),
                        SendRespResult = quic_h3:send_response(Conn, StreamId, Status, RespHeaders),
                        error_logger:info_msg("h3 send_response result=~p~n", [SendRespResult]),
                        SendDataResult = quic_h3:send_data(Conn, StreamId, RespBody, true),
                        error_logger:info_msg("h3 send_data result=~p~n", [SendDataResult]),
                        ok;
                    {error, ProxyReason} ->
                        error_logger:warning_msg("h3 proxy_to_admin failed: ~p~n", [ProxyReason]),
                        ok = quic_h3:send_response(
                            Conn, StreamId, 502, [{<<"content-type">>, <<"text/plain">>}]
                        ),
                        _ = quic_h3:send_data(Conn, StreamId, <<"Bad Gateway">>, true),
                        ok
                end;
            false ->
                ok = quic_h3:send_response(
                    Conn, StreamId, 404, [{<<"content-type">>, <<"text/plain">>}]
                ),
                _ = quic_h3:send_data(Conn, StreamId, <<"Not Found">>, true),
                ok
        end
    catch
        Class:Reason:Stack ->
            error_logger:error_msg(
                "h3 handle_request crash class=~p reason=~p stack=~p~n",
                [Class, Reason, Stack]
            ),
            _ = catch quic_h3:send_response(
                Conn, StreamId, 500, [{<<"content-type">>, <<"text/plain">>}]
            ),
            _ = catch quic_h3:send_data(Conn, StreamId, <<"Internal Server Error">>, true),
            ok
    end.

is_api_path(<<"/api/", _/binary>>) -> true;
is_api_path(_) -> false.

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
    ReqHeaders = h3_headers_to_httpc(Headers),
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
    %% Require an inet6 listener so UDP/443 is definitely reachable via IPv6.
    %% Do not silently fall back to inet-only; that masks production IPv6 outages.
    V6Opts = BaseOpts#{
        quic_opts => maps:merge(
            maps:get(quic_opts, BaseOpts, #{}),
            #{
                socket_backend => socket,
                backend => socket,
                reuseport => false,
                pool_size => 0,
                extra_socket_opts => [inet6]
            }
        )
    },
    error_logger:info_msg("H3 v6 quic_opts: ~p~n", [maps:get(quic_opts, V6Opts, #{})]),
    case quic_h3:start_server(ServerName, Port, V6Opts) of
        {ok, _Pid} = Ok ->
            Ok;
        {error, V6Reason} ->
            {error, {failed_ipv6_listener, V6Reason}}
    end.

load_cert_and_key(Config) ->
    CertPath = maps:get(tls_cert_file, Config, "priv/tls/listener.pem"),
    KeyPath = maps:get(tls_key_file, Config, "priv/tls/listener.key"),
    {ok, CertPem} = file:read_file(CertPath),
    {ok, KeyPem} = file:read_file(KeyPath),
    [CertEntry | _] = public_key:pem_decode(CertPem),
    [KeyEntry | _] = public_key:pem_decode(KeyPem),
    {element(2, CertEntry), public_key:pem_entry_decode(KeyEntry)}.
