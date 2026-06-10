-module(pertisk_eproxy_cowboy_stub_conn_tests).

-include_lib("eunit/include/eunit.hrl").

stub_stream_id_test() ->
    ?assertEqual(1, pertisk_eproxy_cowboy_stub_conn:stub_stream_id()).

start_replies_to_read_body_test() ->
    Parent = self(),
    Pid = pertisk_eproxy_cowboy_stub_conn:start(Parent, <<"body">>),
    true = erlang:unlink(Pid),
    Pid ! {{Pid, 1}, {read_body, self(), make_ref(), 8, 5000}},
    receive
        {request_body, _, fin, 4, <<"body">>} -> ok
    after 1000 ->
        ?assert(false)
    end,
    exit(Pid, shutdown).

captures_response_test() ->
    Parent = self(),
    Pid = pertisk_eproxy_cowboy_stub_conn:start(Parent, <<>>),
    true = erlang:unlink(Pid),
    Body = iolist_to_binary("{}"),
    Pid ! {{Pid, 1}, {response, 200, #{<<"content-type">> => <<"application/json">>}, Body}},
    receive
        {h3_admin_response, 200, _, Body} -> ok
    after 1000 ->
        ?assert(false)
    end,
    exit(Pid, shutdown).

ignores_unknown_message_test() ->
    Parent = self(),
    Pid = pertisk_eproxy_cowboy_stub_conn:start(Parent, <<>>),
    true = erlang:unlink(Pid),
    Pid ! {unknown, message},
    Pid ! {{Pid, 1}, {headers, 200, #{}}},
    exit(Pid, shutdown),
    ok.
