-module(pertisk_eproxy_public_ip_tests).

-include_lib("eunit/include/eunit.hrl").

snapshot_empty_when_not_started_test() ->
    case whereis(pertisk_eproxy_public_ip) of
        undefined -> ok;
        Pid -> exit(Pid, shutdown)
    end,
    S = pertisk_eproxy_public_ip:snapshot(),
    ?assertEqual(null, maps:get(<<"public_ipv4">>, S)),
    ?assertEqual(null, maps:get(<<"public_ipv6">>, S)).

snapshot_after_start_test() ->
    case whereis(pertisk_eproxy_public_ip) of
        undefined -> {ok, _} = pertisk_eproxy_public_ip:start_link();
        _ -> ok
    end,
    S = pertisk_eproxy_public_ip:snapshot(),
    ?assert(is_map(S)),
    ?assert(maps:is_key(<<"public_ipv4">>, S)),
    ?assert(maps:is_key(<<"public_ip_fetched_at_ms">>, S)).
