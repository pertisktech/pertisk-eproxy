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

with_backend_sup(Fun) ->
    Started = case whereis(pertisk_eproxy_backend_sup) of
        undefined ->
            {ok, _} = pertisk_eproxy_backend_sup:start_link(),
            true;
        _ ->
            false
    end,
    try
        Fun()
    after
        case Started of
            true ->
                case whereis(pertisk_eproxy_backend_sup) of
                    undefined -> ok;
                    Pid -> catch gen_server:stop(Pid)
                end;
            false ->
                ok
        end
    end.

backend_sup_start_and_stop_backend_test() ->
    with_backend_sup(fun() ->
        Backend = #{
            name => <<"test-backend">>,
            algorithm => round_robin,
            upstreams => [#{addr => <<"127.0.0.1:8080">>, weight => 1}]
        },
        ?assertMatch({ok, _}, pertisk_eproxy_backend_sup:start_backend(Backend)),
        ?assert(is_pid(pertisk_eproxy_backend:whereis(<<"test-backend">>))),
        ?assertEqual(ok, pertisk_eproxy_backend_sup:stop_backend(<<"test-backend">>)),
        ?assertEqual(undefined, pertisk_eproxy_backend:whereis(<<"test-backend">>))
    end).

backend_sup_stop_backend_idempotent_test() ->
    with_backend_sup(fun() ->
        ?assertEqual(ok, pertisk_eproxy_backend_sup:stop_backend(<<"never-started">>))
    end).

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
