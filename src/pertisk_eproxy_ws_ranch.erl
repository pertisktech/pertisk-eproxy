%% @doc WebSocket reverse proxy on a Ranch-controlled socket (post-HTTP request).
-module(pertisk_eproxy_ws_ranch).

-export([run/4, decode_client_frames/2]).

-define(CONNECT_TIMEOUT, 10000).
-define(MAX_WS_PAYLOAD, 4194304).
-define(MAX_WS_OUT_BUFFER, 64).

-spec run(ranch:ref(), module(), inet:socket() | ssl:sslsocket(), pertisk_req:req()) -> ok.
run(_Ref, Transport, Sock, Req) ->
    try
        run_ws(Transport, Sock, Req)
    catch
        Class:Reason ->
            try lager:warning("WS ranch error ~p:~p", [Class, Reason])
            catch _:_ -> ok
            end,
            ok
    end.

run_ws(Transport, Sock, Req) ->
    case validate_ws_request(Req) of
        {ok, Key} ->
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
            Host = pertisk_req:route_host(Req),
            Path = pertisk_req:path(Req),
            Qs = pertisk_req:qs(Req),
            ClientIp = client_ip(Req),
            case pertisk_eproxy_router:route(Host, Path) of
                {error, no_route} ->
                    _ = Transport:send(Sock, iolist_to_binary(cow_ws:frame(close, #{}))),
                    ok;
                {ok, #{upstream_path := UpPath, backend := BackendName}} ->
                    case pertisk_eproxy_backend:pick_upstream(BackendName, ClientIp) of
                        {error, no_healthy_upstream} ->
                            _ = Transport:send(Sock, iolist_to_binary(cow_ws:frame(close, #{}))),
                            ok;
                        {ok, UpstreamAddr} ->
                            FullPath = case Qs of
                                <<>> -> UpPath;
                                _ -> <<UpPath/binary, "?", Qs/binary>>
                            end,
                            bridge(Transport, Sock, Msgs, Req, Host, BackendName, UpstreamAddr, FullPath)
                    end
            end;
        {error, _} ->
            ok = pertisk_eproxy_http1_codec:write_http_response(Transport, Sock, 400,
                #{<<"content-type">> => <<"text/plain">>, <<"connection">> => <<"close">>},
                <<"Bad WebSocket request">>),
            ok
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

client_ip(Req) ->
    case pertisk_req:header(Req, <<"x-forwarded-for">>) of
        undefined ->
            {PeerIp, _} = pertisk_req:peer(Req),
            list_to_binary(inet:ntoa(PeerIp));
        XFF ->
            hd(binary:split(XFF, [<<", ">>, <<",">>]))
    end.

bridge(Transport, Sock, Msgs, Req, Host, BackendName, UpAddr, FullPath) ->
    {UpHost, UpPort, GunTrans} = pertisk_eproxy_proxy_http:parse_upstream(UpAddr),
    GunOpts = #{transport => GunTrans, protocols => [http], connect_timeout => ?CONNECT_TIMEOUT},
    case gun:open(UpHost, UpPort, GunOpts) of
        {error, _} ->
            _ = Transport:send(Sock, iolist_to_binary(cow_ws:frame(close, #{}))),
            ok;
        {ok, ConnPid} ->
            case gun:await_up(ConnPid, ?CONNECT_TIMEOUT) of
                {error, _} ->
                    gun:close(ConnPid),
                    _ = Transport:send(Sock, iolist_to_binary(cow_ws:frame(close, #{}))),
                    ok;
                {ok, _} ->
                    HdrHost = pertisk_req:route_host(Req),
                    StreamRef = gun:ws_upgrade(ConnPid, FullPath, [{<<"host">>, HdrHost}]),
                    bridge_loop(Transport, Sock, Msgs, ConnPid, StreamRef, <<>>,
                        #{upstream_ready => false, out_buf => [],
                            backend => BackendName, addr => UpAddr, host => Host})
            end
    end.

bridge_loop(Transport, Sock, {TcpOk, TcpClosed, TcpErr}, Gun, SRef, Buf, St) ->
    Ready = maps:get(upstream_ready, St),
    OutBuf = maps:get(out_buf, St),
    receive
        {gun_ws, Gun, SRef, Frame} ->
            ok = send_client_frame(Transport, Sock, Frame),
            bridge_loop(Transport, Sock, {TcpOk, TcpClosed, TcpErr}, Gun, SRef, Buf, St);
        {gun_ws, Gun, SRef, close} ->
            done_ok(St),
            gun:close(Gun),
            ok;
        {gun_upgrade, Gun, SRef, [<<"websocket">>], _} ->
            lists:foreach(fun(F) -> gun:ws_send(Gun, SRef, F) end, OutBuf),
            St2 = St#{upstream_ready => true, out_buf => []},
            bridge_loop(Transport, Sock, {TcpOk, TcpClosed, TcpErr}, Gun, SRef, Buf, St2);
        {gun_error, Gun, _SRef, _} ->
            done_err(St),
            gun:close(Gun),
            ok;
        {gun_down, Gun, _, _, _} ->
            done_ok(St),
            gun:close(Gun),
            ok;
        {TcpOk, Sock, Data} ->
            Buf2 = <<Buf/binary, Data/binary>>,
            case decode_client_frames(Buf2, []) of
                {ok, Rest, Frames} ->
                    St2 = forward_client_frames(Gun, SRef, Frames, Ready, OutBuf, St),
                    bridge_loop(Transport, Sock, {TcpOk, TcpClosed, TcpErr}, Gun, SRef, Rest, St2);
                {error, _} ->
                    done_err(St),
                    gun:close(Gun),
                    ok
            end;
        {TcpClosed, Sock} ->
            done_ok(St),
            gun:close(Gun),
            ok;
        {TcpErr, Sock, _} ->
            done_err(St),
            gun:close(Gun),
            ok
    end.

done_ok(#{backend := B, addr := A}) ->
    catch pertisk_eproxy_backend:done_upstream(B, A, ok);
done_ok(_) ->
    ok.

done_err(#{backend := B, addr := A}) ->
    catch pertisk_eproxy_backend:done_upstream(B, A, error);
done_err(_) ->
    ok.

forward_client_frames(Gun, SRef, Frames, true, _OutBuf, St) ->
    lists:foreach(
        fun
            (close) ->
                gun:ws_send(Gun, SRef, close);
            (F) ->
                gun:ws_send(Gun, SRef, F)
        end,
        Frames
    ),
    St;
forward_client_frames(_Gun, _SRef, Frames, false, OutBuf, St) ->
    case length(OutBuf) + length(Frames) =< ?MAX_WS_OUT_BUFFER of
        true ->
            St#{out_buf => OutBuf ++ Frames};
        false ->
            St
    end.

send_client_frame(Transport, Sock, Frame) ->
    Cow = gun_frame_to_cow(Frame),
    Bin = iolist_to_binary(cow_ws:frame(Cow, #{})),
    Transport:send(Sock, Bin).

gun_frame_to_cow({text, D}) -> {text, ws_io(D)};
gun_frame_to_cow({binary, D}) -> {binary, ws_io(D)};
gun_frame_to_cow(ping) -> ping;
gun_frame_to_cow({ping, D}) -> {ping, ws_io(D)};
gun_frame_to_cow(pong) -> pong;
gun_frame_to_cow({pong, D}) -> {pong, ws_io(D)};
gun_frame_to_cow(close) -> close;
gun_frame_to_cow({close, Code}) when is_integer(Code) ->
    {close, Code, <<>>};
gun_frame_to_cow({close, Payload}) when is_binary(Payload) ->
    {close, 1000, Payload};
gun_frame_to_cow({close, Code, R}) when is_integer(Code) ->
    {close, Code, ws_io(R)};
gun_frame_to_cow({fragment, Fin, Type, D}) ->
    %% Rare from Gun; send as one text frame for interoperability.
    _ = {Fin, Type},
    {text, ws_io(D)};
gun_frame_to_cow(Other) ->
    {text, iolist_to_binary(io_lib:format("~p", [Other]))}.

ws_io(undefined) -> <<>>;
ws_io(null) -> <<>>;
ws_io(B) when is_binary(B) -> B;
ws_io(L) when is_list(L) -> iolist_to_binary(L);
ws_io(O) -> iolist_to_binary(io_lib:format("~p", [O])).

decode_client_frames(<<>>, Acc) ->
    {ok, <<>>, lists:reverse(Acc)};
decode_client_frames(Bin, Acc) ->
    case decode_one_masked(Bin) of
        {ok, Frame, Rest} ->
            decode_client_frames(Rest, [Frame | Acc]);
        need_more ->
            {ok, Bin, lists:reverse(Acc)};
        {error, _} = E ->
            E
    end.

decode_one_masked(<<>>) -> need_more;
decode_one_masked(<<Fin:1, Rsv:3, Op:4, 1:1, Len7:7, Rest0/bits>>) when Rsv =:= 0, Fin =:= 1, Len7 < 126 ->
    need_bytes(Rest0, 4 + Len7, Op, Len7);
decode_one_masked(<<Fin:1, Rsv:3, Op:4, 1:1, 126:7, ExtLen:16, Rest0/bits>>) when Rsv =:= 0, Fin =:= 1 ->
    need_bytes(Rest0, 4 + ExtLen, Op, ExtLen);
decode_one_masked(<<Fin:1, Rsv:3, Op:4, 1:1, 127:7, 0:1, ExtLen:63, Rest0/bits>>)
    when Rsv =:= 0, Fin =:= 1, ExtLen =< ?MAX_WS_PAYLOAD ->
    need_bytes(Rest0, 4 + ExtLen, Op, ExtLen);
decode_one_masked(<<_:1, _:3, _Op:4, 1:1, 127:7, _:64, _/bits>>) ->
    {error, frame_too_large};
decode_one_masked(<<_:1, _:3, _Op:4, 0:1, _/bits>>) ->
    {error, unmasked_client_frame};
decode_one_masked(<<_:1, Rsv:3, _/bits>>) when Rsv =/= 0 ->
    {error, rsv_nonzero};
decode_one_masked(<<0:1, _:3, _/bits>>) ->
    {error, fragmented};
decode_one_masked(_) ->
    need_more.

need_bytes(Bin, Need, _Op, _Len) when byte_size(Bin) < Need ->
    need_more;
need_bytes(Bin, _Need, Op, Len) ->
    <<MaskKey:4/binary, Payload:Len/binary, Rest/binary>> = Bin,
    Unmasked = apply_mask(Payload, MaskKey, <<>>),
    case class_op(Op) of
        {data, text} ->
            {ok, {text, Unmasked}, Rest};
        {data, binary} ->
            {ok, {binary, Unmasked}, Rest};
        control_close ->
            {ok, close, Rest};
        control_ping ->
            {ok, {ping, Unmasked}, Rest};
        control_pong ->
            {ok, {pong, Unmasked}, Rest};
        unsupported ->
            {error, bad_opcode}
    end.

class_op(1) -> {data, text};
class_op(2) -> {data, binary};
class_op(8) -> control_close;
class_op(9) -> control_ping;
class_op(10) -> control_pong;
class_op(_) -> unsupported.

apply_mask(<<>>, _Key, Acc) -> Acc;
apply_mask(Data, Key = <<A, B, C, D>>, Acc) when byte_size(Data) >= 4 ->
    <<P1, P2, P3, P4, Rest/bits>> = Data,
    X = <<(P1 bxor A), (P2 bxor B), (P3 bxor C), (P4 bxor D)>>,
    apply_mask(Rest, Key, <<Acc/binary, X/binary>>);
apply_mask(Data, <<A, B, C, D>>, Acc) ->
    Pad = <<A, B, C, D>>,
    apply_mask_short(Data, Pad, Acc).

apply_mask_short(<<>>, _, Acc) -> Acc;
apply_mask_short(<<P, Rest/bits>>, <<X, Xs/bits>>, Acc) ->
    apply_mask_short(Rest, <<Xs/binary, X>>, <<Acc/binary, (P bxor X)>>).
