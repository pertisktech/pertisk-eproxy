-module(pertisk_eproxy_ws_raw_tests).

-include_lib("eunit/include/eunit.hrl").

connect_handshake_success_test() ->
    {ok, Listen} = gen_tcp:listen(0, [binary, {active, false}, {packet, 0}]),
    {ok, Port} = inet:port(Listen),
    Parent = self(),
    Acceptor = spawn(fun() -> accept_ws_upgrade(Listen, Parent) end),
    Headers = [
        {<<"host">>, <<"127.0.0.1">>},
        {<<"authorization">>, <<"Bearer test">>}
    ],
    Upstream = iolist_to_binary(["http://127.0.0.1:", integer_to_list(Port)]),
    Result = pertisk_eproxy_ws_raw:connect_handshake(Upstream, <<"/ws">>, Headers),
    gen_tcp:close(Listen),
    receive
        {ws_raw_test, done} -> ok
    after 2000 ->
        ok
    end,
    exit(Acceptor, kill),
    ?assertMatch({ok, _, <<>>}, Result).

accept_ws_upgrade(Listen, Parent) ->
    case gen_tcp:accept(Listen) of
        {ok, Socket} ->
            {ok, Request} = read_until_headers_end(Socket, <<>>),
            ?assertMatch(<<"GET /ws ", _/binary>>, Request),
            ?assertNotEqual(nomatch, binary:match(Request, <<"authorization: Bearer test">>)),
            Response =
                "HTTP/1.1 101 Switching Protocols\r\n"
                "Upgrade: websocket\r\n"
                "Connection: Upgrade\r\n"
                "Sec-WebSocket-Accept: dummy\r\n"
                "\r\n",
            ok = gen_tcp:send(Socket, Response),
            Parent ! {ws_raw_test, done},
            gen_tcp:close(Socket);
        {error, _} ->
            Parent ! {ws_raw_test, done}
    end.

read_until_headers_end(Socket, Acc) ->
    case gen_tcp:recv(Socket, 0, 5000) of
        {ok, Data} ->
            Acc1 = <<Acc/binary, Data/binary>>,
            case binary:match(Acc1, <<"\r\n\r\n">>) of
                {_, _} -> {ok, Acc1};
                nomatch -> read_until_headers_end(Socket, Acc1)
            end;
        {error, Reason} ->
            {error, Reason}
    end.
