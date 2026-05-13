%% @doc Ranch protocol: HTTP/1.1 over cleartext TCP or TLS (post-handshake).
-module(pertisk_eproxy_ranch_http1).

-behaviour(ranch_protocol).

-export([start_link/3, init/3]).

start_link(Ref, Transport, Opts) ->
    Pid = spawn_link(?MODULE, init, [Ref, Transport, Opts]),
    {ok, Pid}.

init(Ref, Transport, Opts) ->
    Listener = maps:get(listener, Opts),
    Mode = maps:get(mode, Opts),
    Scheme = maps:get(scheme, Opts),
    Port = maps:get(port, Opts),
    case ranch:handshake(Ref) of
        {ok, Socket} ->
            ok = pertisk_eproxy_http1_codec:setopts(Transport, Socket, [binary, {packet, raw}, {active, false}, {nodelay, true}]),
            loop_connection(Ref, Transport, Socket, Opts, <<>>, Listener, Mode, Scheme, Port);
        {error, _} = Err ->
            log_hs_error(Listener, Err)
    end.

log_hs_error(Listener, Err) ->
    try lager:warning("Ranch TLS handshake failed (~p): ~p", [Listener, Err])
    catch _:_ -> ok
    end.

loop_connection(Ref, Transport, Sock, CodecOpts, Buf0, Listener, Mode, Scheme, ClientPort) ->
    Peer = peer_or_dummy(Transport, Sock),
    case pertisk_eproxy_http1_codec:read_request(Transport, Sock, CodecOpts, Buf0) of
        {ok, R0, Buf1} ->
            Host = normalize_host(maps:get(host, R0, <<>>)),
            Req = pertisk_req:new(#{
                listener => Listener,
                mode => Mode,
                method => maps:get(method, R0),
                path => maps:get(path, R0),
                raw_path => maps:get(raw_path, R0),
                qs => maps:get(qs, R0),
                host => Host,
                route_host => Host,
                headers => maps:get(headers, R0),
                body => maps:get(body, R0, <<>>),
                peer => Peer,
                scheme => Scheme,
                port => ClientPort,
                http_version => maps:get(http_version, R0, <<"HTTP/1.1">>)
            }),
            case pertisk_eproxy_http_dispatch:handle(Req) of
                {http_reply, Status, Hdr, Body} ->
                    ConnHdr = connection_header(maps:get(http_version, R0, <<"HTTP/1.1">>), maps:get(headers, R0)),
                    ok = pertisk_eproxy_http1_codec:write_http_response(Transport, Sock, Status, Hdr, Body),
                    case ConnHdr of
                        close ->
                            safe_remove_connection(Ref, Transport, Sock);
                        keep_alive ->
                            loop_connection(Ref, Transport, Sock, CodecOpts, Buf1, Listener, Mode, Scheme, ClientPort)
                    end;
                {admin_ws, Req1} ->
                    ok = pertisk_eproxy_ws_admin_ranch:run(Ref, Transport, Sock, Req1),
                    safe_remove_connection(Ref, Transport, Sock);
                {ws_proxy, Req1} ->
                    ok = pertisk_eproxy_ws_ranch:run(Ref, Transport, Sock, Req1),
                    safe_remove_connection(Ref, Transport, Sock)
            end;
        {error, closed} ->
            safe_remove_connection(Ref, Transport, Sock);
        {error, Reason} ->
            try lager:debug("HTTP/1 read error (~p): ~p", [Listener, Reason])
            catch _:_ -> ok
            end,
            _ = catch pertisk_eproxy_http1_codec:write_raw(Transport, Sock,
                <<"HTTP/1.1 400 Bad Request\r\nconnection: close\r\ncontent-length: 11\r\n\r\nBad Request">>),
            safe_remove_connection(Ref, Transport, Sock)
    end.

safe_remove_connection(Ref, Transport, Sock) ->
    _ = catch ranch:remove_connection(Ref),
    catch pertisk_eproxy_http1_codec:close(Transport, Sock),
    ok.

peer_or_dummy(Transport, Sock) ->
    case Transport:peername(Sock) of
        {ok, P} -> P;
        _ -> {{0, 0, 0, 0}, 0}
    end.

connection_header(<<"HTTP/1.0">>, _Hdrs) ->
    close;
connection_header(_Ver, Hdrs) ->
    case maps:get(<<"connection">>, Hdrs, <<>>) of
        <<>> ->
            keep_alive;
        C0 ->
            C = string:lowercase(C0),
            case binary:match(C, <<"close">>) of
                nomatch -> keep_alive;
                _ -> close
            end
    end.

normalize_host(H) ->
    case binary:split(H, <<":">>) of
        [Host, _Port] -> string:lowercase(Host);
        _ -> string:lowercase(H)
    end.
