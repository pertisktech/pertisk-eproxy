-module(pertisk_ingress_status_tests).

-include_lib("eunit/include/eunit.hrl").

ensure_ingress_tls() ->
    case whereis(pertisk_ingress_tls) of
        undefined -> {ok, _} = pertisk_ingress_tls:start_link();
        _ -> ok
    end.

init_and_record_success_test() ->
    ok = pertisk_ingress_status:init(),
    ensure_ingress_tls(),
    ok = pertisk_ingress_status:record_success([site], [be1, be2], [t1, t2, t3]),
    S = pertisk_ingress_status:snapshot(),
    ?assert(is_integer(maps:get(<<"last_success_at">>, S))),
    ?assertEqual(<<"connected">>, maps:get(<<"watcher">>, S)),
    ?assertEqual(null, maps:get(<<"last_error">>, S)).

record_error_test() ->
    ok = pertisk_ingress_status:init(),
    ensure_ingress_tls(),
    ok = pertisk_ingress_status:record_error(<<"boom">>),
    S = pertisk_ingress_status:snapshot(),
    ?assertEqual(<<"boom">>, maps:get(<<"last_error">>, S)).

set_leader_and_watcher_test() ->
    ok = pertisk_ingress_status:init(),
    ensure_ingress_tls(),
    ok = pertisk_ingress_status:set_leader(true),
    ok = pertisk_ingress_status:set_watcher_state(connected),
    S = pertisk_ingress_status:snapshot(),
    ?assertEqual(true, maps:get(<<"leader">>, S)),
    ?assertEqual(<<"connected">>, maps:get(<<"watcher">>, S)).

ready_from_runtime_when_ingress_disabled_test() ->
    Old = os:getenv("PERTISK_MODE"),
    os:unsetenv("PERTISK_MODE"),
    try
        ?assertEqual(ok, pertisk_ingress_status:ready_from_runtime())
    after
        case Old of false -> ok; V -> os:putenv("PERTISK_MODE", V) end
    end.

live_ok_test() ->
    ok = pertisk_ingress_status:init(),
    ?assertEqual(ok, pertisk_ingress_status:live_ok()).
