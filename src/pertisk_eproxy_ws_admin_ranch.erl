%% @doc Admin SPA WebSocket on Ranch (HTTP/1.1): same stream as pertisk_eproxy_admin_ws_handler.
-module(pertisk_eproxy_ws_admin_ranch).

-export([run/4]).

-define(TICK_MS, 2000).

-spec run(ranch:ref(), module(), inet:socket() | ssl:sslsocket(), pertisk_req:req()) -> ok.
run(_Ref, Transport, Sock, Req) ->
    try
        run1(Transport, Sock, Req)
    catch
        Class:Reason:Stack ->
            try lager:warning("WS admin ranch ~p:~p~n~p", [Class, Reason, Stack])
            catch _:_ -> ok
            end,
            ok
    end.

run1(Transport, Sock, Req) ->
    case authorize(Req) of
        {error, unauthorized} ->
            ok = pertisk_eproxy_http1_codec:write_http_response(Transport, Sock, 401,
                #{<<"content-type">> => <<"application/json">>, <<"connection">> => <<"close">>},
                <<"{\"error\":\"Unauthorized\"}">>),
            ok;
        ok ->
            case validate_ws_request(Req) of
                {ok, Key} ->
                    log_upgrade(Req),
                    Accept = cow_ws:encode_key(Key),
                    Lines = [
                        <<"HTTP/1.1 101 Switching Protocols\r\n">>,
                        <<"upgrade: websocket\r\n">>,
                        <<"connection: Upgrade\r\n">>,
                        <<"sec-websocket-accept: ">>, Accept, <<"\r\n">>,
                        <<"\r\n">>
                    ],
                    ok = Transport:send(Sock, iolist_to_binary(Lines)),
                    ok = Transport:setopts(Sock, [binary, {packet, raw}, {active, true}]),
                    Msgs = Transport:messages(),
                    ok = pertisk_eproxy_admin_realtime:subscribe(self()),
                    TRef = erlang:send_after(?TICK_MS, self(), tick),
                    ok = send_text(Transport, Sock, snapshot_json()),
                    loop(Transport, Sock, Msgs, <<>>, #{timer_ref => TRef});
                {error, _} ->
                    ok = pertisk_eproxy_http1_codec:write_http_response(Transport, Sock, 400,
                        #{<<"content-type">> => <<"text/plain">>, <<"connection">> => <<"close">>},
                        <<"Bad WebSocket request">>),
                    ok
            end
    end.

authorize(Req) ->
    case pertisk_eproxy_auth:auth_mode() of
        disabled ->
            ok;
        local ->
            Qm = maps:from_list(pertisk_req:qparse(Req)),
            case maps:get(<<"token">>, Qm, <<>>) of
                <<>> ->
                    {error, unauthorized};
                Token ->
                    case pertisk_eproxy_auth:verify_token(Token) of
                        {ok, _} -> ok;
                        _ -> {error, unauthorized}
                    end
            end;
        _ ->
            {error, unauthorized}
    end.

validate_ws_request(Req) ->
    Key = pertisk_req:header(Req, <<"sec-websocket-key">>, undefined),
    Ver = pertisk_req:header(Req, <<"sec-websocket-version">>, <<>>),
    case {Key, Ver} of
        {K, <<"13">>} when is_binary(K), byte_size(K) > 0 ->
            {ok, K};
        {K, _} when is_binary(K), byte_size(K) > 0 ->
            {ok, K};
        _ ->
            {error, bad_ws_handshake}
    end.

log_upgrade(Req) ->
    Host = pertisk_req:route_host(Req),
    Path = pertisk_req:path(Req),
    catch pertisk_eproxy_access_log:log_proxy(Host, <<"GET">>, Path, 101, 0, 'HTTP/1.1', <<"admin_ws">>).

loop(Transport, Sock, {TcpOk, TcpClosed, TcpErr} = Msgs, Buf, St = #{timer_ref := TRef}) ->
    receive
        {admin_ws_push, Bin} when is_binary(Bin) ->
            ok = send_text(Transport, Sock, Bin),
            loop(Transport, Sock, Msgs, Buf, St);
        tick ->
            ok = send_text(Transport, Sock, snapshot_json()),
            _ = erlang:cancel_timer(TRef),
            TRef2 = erlang:send_after(?TICK_MS, self(), tick),
            loop(Transport, Sock, Msgs, Buf, St#{timer_ref => TRef2});
        {TcpOk, Sock, Data} ->
            Buf2 = <<Buf/binary, Data/binary>>,
            case pertisk_eproxy_ws_ranch:decode_client_frames(Buf2, []) of
                {ok, Rest, Frames} ->
                    ok = handle_client_frames(Transport, Sock, Frames),
                    loop(Transport, Sock, Msgs, Rest, St);
                {error, _} ->
                    cleanup(St),
                    ok
            end;
        {TcpClosed, Sock} ->
            cleanup(St),
            ok;
        {TcpErr, Sock, _} ->
            cleanup(St),
            ok;
        _ ->
            loop(Transport, Sock, Msgs, Buf, St)
    end.

cleanup(#{timer_ref := TRef}) ->
    _ = catch erlang:cancel_timer(TRef),
    _ = catch pertisk_eproxy_admin_realtime:unsubscribe(self()),
    ok.

handle_client_frames(Transport, Sock, Frames) ->
    lists:foreach(
        fun
            (close) ->
                ok;
            ({ping, P}) ->
                Bin = iolist_to_binary(cow_ws:frame({pong, ws_io(P)}, #{})),
                _ = Transport:send(Sock, Bin);
            (ping) ->
                Bin = iolist_to_binary(cow_ws:frame(pong, #{})),
                _ = Transport:send(Sock, Bin);
            (_) ->
                ok
        end,
        Frames
    ),
    ok.

send_text(Transport, Sock, Text) when is_binary(Text) ->
    Bin = iolist_to_binary(cow_ws:frame({text, Text}, #{})),
    Transport:send(Sock, Bin).

ws_io(undefined) -> <<>>;
ws_io(null) -> <<>>;
ws_io(B) when is_binary(B) -> B;
ws_io(L) when is_list(L) -> iolist_to_binary(L);
ws_io(O) -> iolist_to_binary(io_lib:format("~p", [O])).

snapshot_json() ->
    Data = #{
        <<"stats">> => pertisk_eproxy_stats:snapshot(),
        <<"management">> => pertisk_eproxy_admin_management_snapshot:snapshot(),
        <<"logs">> => pertisk_eproxy_access_log:list(undefined, undefined),
        <<"certificates">> => certificate_rows(),
        <<"ssl_jobs">> => pertisk_eproxy_admin_realtime:ssl_jobs_snapshot()
    },
    thoas:encode(Data).

certificate_rows() ->
    case pertisk_eproxy_db:list_certificates(db_file_path()) of
        {ok, Certs} ->
            [#{
                <<"id">> => integer_to_binary(maps:get(id, C)),
                <<"hosts">> => [json_text(maps:get(name, C, <<>>))],
                <<"source_type">> => json_text(maps:get(source_type, C, <<"acme">>)),
                <<"challenge">> => challenge_for_source(maps:get(source_type, C, <<"acme">>))
             } || C <- Certs];
        _ ->
            []
    end.

challenge_for_source(Src0) ->
    Src = json_text(Src0),
    case Src of
        <<"imported_pem">> -> <<"imported PEM">>;
        _ -> <<"acme">>
    end.

db_file_path() ->
    case application:get_env(pertisk_eproxy, db_file) of
        {ok, F} when is_list(F) -> F;
        {ok, F} when is_binary(F) -> binary_to_list(F);
        _ -> "data/proxy.db"
    end.

json_text(V) when is_binary(V) -> V;
json_text(V) when is_list(V) -> list_to_binary(V);
json_text(V) -> iolist_to_binary(io_lib:format("~p", [V])).
