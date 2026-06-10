-module(pertisk_eproxy_public_ip_tests).

-include_lib("eunit/include/eunit.hrl").

%% ---------------------------------------------------------------------------
%% snapshot/0 tests
%% ---------------------------------------------------------------------------

snapshot_returns_map_when_server_not_running_test() ->
    Result = pertisk_eproxy_public_ip:snapshot(),
    ?assert(is_map(Result)),
    ?assertEqual(null, maps:get(<<"public_ipv4">>, Result)),
    ?assertEqual(null, maps:get(<<"public_ipv6">>, Result)),
    ?assertEqual(null, maps:get(<<"public_ip_fetched_at_ms">>, Result)),
    ?assertEqual(null, maps:get(<<"public_ip_error">>, Result)).