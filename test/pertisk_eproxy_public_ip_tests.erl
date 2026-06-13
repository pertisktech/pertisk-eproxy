-module(pertisk_eproxy_public_ip_tests).

-include_lib("eunit/include/eunit.hrl").

snapshot_returns_map_when_server_not_running_test() ->
    Result = pertisk_eproxy_public_ip:snapshot(),
    ?assert(is_map(Result)),
    ?assertEqual(null, maps:get(<<"public_ipv4">>, Result)),
    ?assertEqual(null, maps:get(<<"public_ipv6">>, Result)),
    ?assertEqual(null, maps:get(<<"public_ip_fetched_at_ms">>, Result)),
    ?assertEqual(null, maps:get(<<"public_ip_error">>, Result)).

snapshot_after_refresh_test() ->
    with_public_ip(fun(Pid) ->
        timer:sleep(100),
        Result = pertisk_eproxy_public_ip:snapshot(),
        ?assertEqual(<<"203.0.113.1">>, maps:get(<<"public_ipv4">>, Result)),
        ?assertEqual(<<"2001:db8::1">>, maps:get(<<"public_ipv6">>, Result)),
        ?assertEqual(null, maps:get(<<"public_ip_error">>, Result)),
        ?assert(is_integer(maps:get(<<"public_ip_fetched_at_ms">>, Result))),
        ?assertEqual({error, unknown}, gen_server:call(Pid, unknown, 5000))
    end).

snapshot_fetch_failure_sets_error_test() ->
    with_public_ip(fun(_Pid) ->
        timer:sleep(100),
        Result = pertisk_eproxy_public_ip:snapshot(),
        ?assertEqual(null, maps:get(<<"public_ipv4">>, Result)),
        ?assertEqual(null, maps:get(<<"public_ipv6">>, Result)),
        Err = maps:get(<<"public_ip_error">>, Result),
        ?assert(is_binary(Err)),
        ?assert(byte_size(Err) > 0)
    end, fail_responses()).

snapshot_trims_whitespace_from_body_test() ->
    with_public_ip(fun(_Pid) ->
        timer:sleep(100),
        Result = pertisk_eproxy_public_ip:snapshot(),
        ?assertEqual(<<"198.51.100.9">>, maps:get(<<"public_ipv4">>, Result)),
        ?assertEqual(<<"2001:db8::2">>, maps:get(<<"public_ipv6">>, Result))
    end, trim_responses()).

with_public_ip(Fun) ->
    with_public_ip(Fun, ok_responses()).

with_public_ip(Fun, ResponseFun) when is_function(ResponseFun, 4) ->
    stop_public_ip(),
    unload_httpc(),
    meck:new(httpc, [unstick]),
    meck:expect(httpc, request, ResponseFun),
    {ok, Pid} = pertisk_eproxy_public_ip:start_link(),
    try
        Fun(Pid)
    after
        pertisk_eproxy_test_helpers:safe_gen_server_stop(Pid),
        unload_httpc()
    end.

ok_responses() ->
    fun
        (get, {"http://api4.ipify.org", _}, _, _) ->
            {ok, {{http, 200, 'OK'}, [], <<"203.0.113.1">>}};
        (get, {"http://api6.ipify.org", _}, _, _) ->
            {ok, {{http, 200, 'OK'}, [], <<"2001:db8::1">>}}
    end.

fail_responses() ->
    fun(_, _, _, _) -> {error, timeout} end.

trim_responses() ->
    fun
        (get, {"http://api4.ipify.org", _}, _, _) ->
            {ok, {{http, 200, 'OK'}, [], <<"  198.51.100.9\n">>}};
        (get, {"http://api6.ipify.org", _}, _, _) ->
            {ok, {{http, 200, 'OK'}, [], "2001:db8::2"}}
    end.

stop_public_ip() ->
    case whereis(pertisk_eproxy_public_ip) of
        undefined -> ok;
        Pid -> pertisk_eproxy_test_helpers:safe_gen_server_stop(Pid)
    end.

unload_httpc() ->
    case lists:member(httpc, meck:mocked()) of
        true -> pertisk_eproxy_test_helpers:unload_mocks([httpc]);
        false -> ok
    end.
