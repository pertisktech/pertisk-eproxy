-module(pertisk_ingress_sup_tests).

-include_lib("eunit/include/eunit.hrl").

ingress_sup_init_test() ->
    {ok, {Flags, Children}} = pertisk_ingress_sup:init([]),
    ?assertEqual(one_for_one, maps:get(strategy, Flags)),
    ?assertEqual(5, maps:get(intensity, Flags)),
    ?assertEqual(30, maps:get(period, Flags)),
    Ids = [maps:get(id, C) || C <- Children],
    ?assertEqual(
        [pertisk_ingress_tls, pertisk_ingress_leader, pertisk_ingress_watcher],
        Ids
    ),
    lists:foreach(
        fun(Child) ->
            ?assertEqual(permanent, maps:get(restart, Child)),
            ?assertEqual(worker, maps:get(type, Child))
        end,
        Children
    ).
