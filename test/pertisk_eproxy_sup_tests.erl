-module(pertisk_eproxy_sup_tests).

-include_lib("eunit/include/eunit.hrl").

proxy_sup_init_test() ->
    {ok, {Flags, Children}} = pertisk_eproxy_sup:init([]),
    ?assertEqual(one_for_one, maps:get(strategy, Flags)),
    ?assert(length(Children) >= 8).

backend_sup_init_test() ->
    {ok, {Flags, Children}} = pertisk_eproxy_backend_sup:init([]),
    ?assertEqual(one_for_one, maps:get(strategy, Flags)),
    ?assertEqual([], Children).
