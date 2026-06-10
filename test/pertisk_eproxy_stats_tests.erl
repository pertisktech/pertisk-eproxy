-module(pertisk_eproxy_stats_tests).

-include_lib("eunit/include/eunit.hrl").

snapshot_returns_map_test() ->
    application:ensure_all_started(prometheus),
    pertisk_eproxy_metrics:setup(),
    S = pertisk_eproxy_stats:snapshot(),
    ?assert(is_map_key(<<"h2_requests_total">>, S)),
    ?assert(is_map_key(<<"h3_requests_total">>, S)),
    ?assert(is_map_key(<<"uptime_secs">>, S)).

is_map_key(K, Map) ->
    maps:is_key(K, Map).
