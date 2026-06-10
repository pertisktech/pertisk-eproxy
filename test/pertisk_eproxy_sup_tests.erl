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

proxy_sup_start_link_test() ->
    meck:new(supervisor, [unstick]),
    meck:expect(supervisor, start_link, fun
        ({local, pertisk_eproxy_sup}, pertisk_eproxy_sup, []) -> {ok, self()}
    end),
    try
        {ok, Pid} = pertisk_eproxy_sup:start_link(),
        ?assert(is_pid(Pid))
    after
        meck:unload(supervisor)
    end.

proxy_sup_ingress_child_when_enabled_test() ->
    meck:new(pertisk_ingress_env, [unstick, passthrough]),
    meck:expect(pertisk_ingress_env, enabled, fun() -> true end),
    try
        {ok, {_Flags, Children}} = pertisk_eproxy_sup:init([]),
        Ids = [maps:get(id, C) || C <- Children],
        ?assert(lists:member(pertisk_ingress_sup, Ids))
    after
        meck:unload(pertisk_ingress_env)
    end.

proxy_sup_no_ingress_child_when_disabled_test() ->
    meck:new(pertisk_ingress_env, [unstick, passthrough]),
    meck:expect(pertisk_ingress_env, enabled, fun() -> false end),
    try
        {ok, {_Flags, Children}} = pertisk_eproxy_sup:init([]),
        Ids = [maps:get(id, C) || C <- Children],
        ?assertNot(lists:member(pertisk_ingress_sup, Ids))
    after
        meck:unload(pertisk_ingress_env)
    end.
