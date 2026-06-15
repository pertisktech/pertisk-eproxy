%% @doc Raw TCP/TLS WebSocket client for k8s loopback upstreams.
%%
%% Some upstreams (e.g. Omni kube proxy on 127.0.0.1:8100) accept WebSocket
%% upgrades from nginx/curl but close gun's ws_upgrade handshake. This module
%% performs a manual HTTP/1.1 upgrade and frames I/O with cow_ws.
-module(pertisk_eproxy_ws_raw).

-export([connect_handshake/3, start_reader/3, send_frame/2, close_upstream/2]).

-define(HANDSHAKE_TIMEOUT_MS, 10000).
-define(MAX_HEADER_BYTES, 65536).

%% @doc Returns {ok, {Socket, Transport}, BufferedWsData} or {error, Reason}.
-spec connect_handshake(binary(), binary(), [{binary(), binary()}]) ->
    {ok, {port(), tcp | tls}, binary()} | {error, term()}.
connect_handshake(UpstreamAddr, Path, Headers) ->
    {Host, Port, Transport} = pertisk_eproxy_handler:parse_upstream(UpstreamAddr),
    case open_socket(Transport, Host, Port) of
        {error, Reason} ->
            {error, Reason};
        {ok, Socket} ->
            Request = build_upgrade_request(Path, Headers),
            case send_all(Socket, Transport, Request) of
                ok ->
                    case read_upgrade_response(Socket, Transport, <<>>) of
                        {ok, Rest} ->
                            {ok, {Socket, Transport}, Rest};
                        {error, Reason} ->
                            close_socket(Socket, Transport),
                            {error, Reason}
                    end;
                {error, Reason} ->
                    close_socket(Socket, Transport),
                    {error, Reason}
            end
    end.

-spec start_reader(pid(), {port(), tcp | tls}, binary()) -> {ok, pid()}.
start_reader(Parent, {Socket, Transport}, InitialBuf) ->
    Pid = spawn_link(fun() -> reader_loop(Parent, Socket, Transport, InitialBuf) end),
    {ok, Pid}.

-spec send_frame({port(), tcp | tls}, term()) -> ok | {error, term()}.
send_frame({Socket, Transport}, Frame) ->
    send_all(Socket, Transport, encode_frame(Frame)).

-spec close_upstream({port(), tcp | tls}, pid() | undefined) -> ok.
close_upstream({Socket, Transport}, ReaderPid) ->
    case ReaderPid of
        Pid when is_pid(Pid) ->
            catch exit(Pid, shutdown);
        _ ->
            ok
    end,
    close_socket(Socket, Transport).

%% -------------------------------------------------------------------------
%% Handshake
%% -------------------------------------------------------------------------

open_socket(tls, Host, Port) ->
    SslOpts = [
        binary,
        {active, false},
        {verify, verify_none},
        {server_name_indication, disable}
    ],
    case ssl:connect(Host, Port, SslOpts, ?HANDSHAKE_TIMEOUT_MS) of
        {error, Reason} -> {error, Reason};
        {ok, Socket} -> {ok, Socket}
    end;
open_socket(_Transport, Host, Port) ->
    case gen_tcp:connect(Host, Port, [binary, {active, false}], ?HANDSHAKE_TIMEOUT_MS) of
        {error, Reason} -> {error, Reason};
        {ok, Socket} -> {ok, Socket}
    end.

build_upgrade_request(Path, Headers) ->
    Key = cow_ws:key(),
    UpgradeHeaders = [
        {<<"connection">>, <<"upgrade">>},
        {<<"upgrade">>, <<"websocket">>},
        {<<"sec-websocket-version">>, <<"13">>},
        {<<"sec-websocket-key">>, Key}
        | Headers
    ],
    HeaderLines = [
        [K, <<": ">>, V, <<"\r\n">>]
     || {K, V} <- UpgradeHeaders
    ],
    iolist_to_binary([
        <<"GET ">>, Path, <<" HTTP/1.1\r\n">>,
        HeaderLines,
        <<"\r\n">>
    ]).

read_upgrade_response(Socket, Transport, Acc) ->
    case recv(Socket, Transport, 0, ?HANDSHAKE_TIMEOUT_MS) of
        {ok, Data} ->
            Acc1 = <<Acc/binary, Data/binary>>,
            case binary:match(Acc1, <<"\r\n\r\n">>) of
                {Pos, _} ->
                    HeaderPart = binary:part(Acc1, 0, Pos),
                    Rest = binary:part(Acc1, Pos + 4, byte_size(Acc1) - Pos - 4),
                    case parse_response_status(HeaderPart) of
                        {101, _} ->
                            {ok, Rest};
                        {Status, _} ->
                            {error, {bad_status, Status, HeaderPart}}
                    end;
                nomatch when byte_size(Acc1) > ?MAX_HEADER_BYTES ->
                    {error, headers_too_large};
                nomatch ->
                    read_upgrade_response(Socket, Transport, Acc1)
            end;
        {error, Reason} ->
            {error, Reason}
    end.

parse_response_status(HeaderPart) ->
    case binary:split(HeaderPart, <<"\r\n">>, [global, trim_all]) of
        [StatusLine | _] ->
            case binary:split(StatusLine, <<" ">>, [global]) of
                [<<"HTTP/1.1">>, StatusBin | _] ->
                    {binary_to_integer(StatusBin), StatusLine};
                [<<"HTTP/1.0">>, StatusBin | _] ->
                    {binary_to_integer(StatusBin), StatusLine};
                _ ->
                    {0, StatusLine}
            end;
        _ ->
            {0, HeaderPart}
    end.

%% -------------------------------------------------------------------------
%% Reader
%% -------------------------------------------------------------------------

reader_loop(Parent, Socket, Transport, Buf) ->
    case decode_frames(Buf, []) of
        {ok, Frames, Rest} ->
            lists:foreach(
                fun
                    (close) -> Parent ! {ws_raw, close};
                    (Frame) -> Parent ! {ws_raw, Frame}
                end,
                Frames
            ),
            read_socket_loop(Parent, Socket, Transport, Rest);
        need_more ->
            case recv(Socket, Transport, 0, infinity) of
                {ok, Data} ->
                    reader_loop(Parent, Socket, Transport, <<Buf/binary, Data/binary>>);
                {error, _} ->
                    Parent ! {ws_raw, close},
                    close_socket(Socket, Transport)
            end;
        {error, _} ->
            Parent ! {ws_raw, close},
            close_socket(Socket, Transport)
    end.

read_socket_loop(Parent, Socket, Transport, Buf) ->
    reader_loop(Parent, Socket, Transport, Buf).

decode_frames(<<>>, Acc) ->
    {ok, lists:reverse(Acc), <<>>};
decode_frames(Data, Acc) ->
    case decode_one_frame(Data) of
        {ok, Frame, Rest} ->
            decode_frames(Rest, [Frame | Acc]);
        need_more ->
            {ok, lists:reverse(Acc), Data};
        close ->
            {ok, lists:reverse([close | Acc]), <<>>};
        {error, _} = Err ->
            Err
    end.

decode_one_frame(<<>>) ->
    need_more;
decode_one_frame(<<_Fin:1, _Rsv:3, 8:4, _/bits>>) ->
    close;
decode_one_frame(Data) ->
    try decode_one_frame_unmasked(Data) of
        need_more ->
            need_more;
        {ok, Frame, Rest} ->
            {ok, Frame, Rest}
    catch
        _:_ ->
            decode_one_frame_masked(Data)
    end.

decode_one_frame_unmasked(<<_Fin:1, _Rsv:3, Opcode:4, 0:1, Len:7, Rest/binary>>)
    when Len < 126 ->
    frame_from_opcode(Opcode, Len, Rest);
decode_one_frame_unmasked(<<_Fin:1, _Rsv:3, Opcode:4, 0:1, 126:7, Len:16, Rest/binary>>)
    when Len =< ?MAX_HEADER_BYTES ->
    frame_from_opcode(Opcode, Len, Rest);
decode_one_frame_unmasked(<<_Fin:1, _Rsv:3, Opcode:4, 0:1, 127:7, 0:1, Len:63, Rest/binary>>)
    when Len =< ?MAX_HEADER_BYTES ->
    frame_from_opcode(Opcode, Len, Rest);
decode_one_frame_unmasked(_) ->
    need_more.

decode_one_frame_masked(<<_Fin:1, _Rsv:3, Opcode:4, 1:1, Len:7, Mask:32, Rest/binary>>)
    when Len < 126 ->
    case Rest of
        <<Payload:Len/binary, Tail/binary>> ->
            {ok, frame_value(Opcode, unmask(Payload, Mask)), Tail};
        _ ->
            need_more
    end;
decode_one_frame_masked(_) ->
    need_more.

frame_from_opcode(Opcode, Len, Rest) ->
    case Rest of
        <<Payload:Len/binary, Tail/binary>> ->
            {ok, frame_value(Opcode, Payload), Tail};
        _ ->
            need_more
    end.

frame_value(1, Payload) -> {text, Payload};
frame_value(2, Payload) -> {binary, Payload};
frame_value(9, _) -> ping;
frame_value(10, _) -> pong;
frame_value(_, Payload) -> {binary, Payload}.

unmask(Payload, Mask) ->
    unmask(Payload, Mask, 0, <<>>).

unmask(<<>>, _Mask, _I, Acc) ->
    Acc;
unmask(<<B, Rest/binary>>, Mask, I, Acc) ->
    <<M:8>> = <<Mask:32>>,
    Masked = B bxor (M bsr ((3 - (I rem 4)) * 8)),
    unmask(Rest, Mask, I + 1, <<Acc/binary, Masked>>).

%% -------------------------------------------------------------------------
%% Encode / socket helpers
%% -------------------------------------------------------------------------

encode_frame(ping) ->
    cow_ws:frame(ping);
encode_frame(pong) ->
    cow_ws:frame(pong);
encode_frame(close) ->
    cow_ws:frame(close);
encode_frame({text, Data}) ->
    cow_ws:frame({text, Data});
encode_frame({binary, Data}) ->
    cow_ws:frame({binary, Data});
encode_frame({close, Code, Reason}) when is_integer(Code) ->
    cow_ws:frame({close, Code, Reason});
encode_frame({Frame, Data}) ->
    cow_ws:frame({Frame, Data}).

send_all(Socket, tcp, Data) ->
    gen_tcp:send(Socket, Data);
send_all(Socket, tls, Data) ->
    ssl:send(Socket, Data).

recv(Socket, tcp, Length, Timeout) ->
    gen_tcp:recv(Socket, Length, Timeout);
recv(Socket, tls, Length, Timeout) ->
    ssl:recv(Socket, Length, Timeout).

close_socket(Socket, tcp) ->
    catch gen_tcp:close(Socket);
close_socket(Socket, tls) ->
    catch ssl:close(Socket).
