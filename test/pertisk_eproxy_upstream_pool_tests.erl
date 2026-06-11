-module(pertisk_eproxy_upstream_pool_tests).

-include_lib("eunit/include/eunit.hrl").

-define(HOST, <<"127.0.0.1">>).
-define(PORT, 18080).
-define(TRANSPORT, tcp).
-define(REQ_KIND, http).
-define(GUN_OPTS, #{connect_timeout => 500, protocols => [http]}).

invalidate_undefined_test() ->
    ?assertEqual(ok, pertisk_eproxy_upstream_pool:invalidate(undefined)).

invalidate_dead_pid_test() ->
    ?assertEqual(ok, pertisk_eproxy_upstream_pool:invalidate(list_to_pid("<0.2.0>"))).

checkout_without_pool_opens_connection_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_deps(),
    case pertisk_eproxy_upstream_pool:checkout(
        "127.0.0.1",
        1,
        tcp,
        http,
        #{connect_timeout => 200, protocols => [http]}
    ) of
        {ok, Pid} ->
            catch gun:close(Pid),
            ok;
        {error, _} ->
            ok
    end.

checkout_reuses_pooled_connection_test() ->
    with_pool_and_gun(fun(_Pool) ->
        {ok, Pid1} = pertisk_eproxy_upstream_pool:checkout(
            ?HOST, ?PORT, ?TRANSPORT, ?REQ_KIND, ?GUN_OPTS
        ),
        {ok, Pid2} = pertisk_eproxy_upstream_pool:checkout(
            ?HOST, ?PORT, ?TRANSPORT, ?REQ_KIND, ?GUN_OPTS
        ),
        ?assertEqual(Pid1, Pid2)
    end).

invalidate_removes_from_pool_test() ->
    with_pool_and_gun(fun(_Pool) ->
        {ok, Pid} = pertisk_eproxy_upstream_pool:checkout(
            ?HOST, ?PORT, ?TRANSPORT, ?REQ_KIND, ?GUN_OPTS
        ),
        ok = pertisk_eproxy_upstream_pool:invalidate(Pid),
        ?assertEqual(
            empty,
            gen_server:call(
                pertisk_eproxy_upstream_pool,
                {try_checkout, ?HOST, ?PORT, ?TRANSPORT, ?REQ_KIND},
                5000
            )
        )
    end).

unknown_call_returns_error_test() ->
    with_pool(fun(_Pool) ->
        ?assertEqual(
            {error, unknown_call},
            gen_server:call(pertisk_eproxy_upstream_pool, bogus, 5000)
        )
    end).

sweep_idle_removes_dead_connections_test() ->
    with_pool_and_gun(fun(Pool) ->
        {ok, Pid} = pertisk_eproxy_upstream_pool:checkout(
            ?HOST, ?PORT, ?TRANSPORT, ?REQ_KIND, ?GUN_OPTS
        ),
        exit(Pid, kill),
        Pool ! sweep_idle,
        timer:sleep(50),
        ?assertEqual(
            empty,
            gen_server:call(
                Pool,
                {try_checkout, ?HOST, ?PORT, ?TRANSPORT, ?REQ_KIND},
                5000
            )
        )
    end).

pick_rr_rotates_connections_test() ->
    with_pool(fun(Pool) ->
        PidA = fake_conn(),
        PidB = fake_conn(),
        gen_server:cast(Pool, {register, ?HOST, ?PORT, ?TRANSPORT, ?REQ_KIND, ?GUN_OPTS, PidA}),
        gen_server:cast(Pool, {register, ?HOST, ?PORT, ?TRANSPORT, ?REQ_KIND, ?GUN_OPTS, PidB}),
        timer:sleep(20),
        {ok, First} = gen_server:call(
            Pool, {try_checkout, ?HOST, ?PORT, ?TRANSPORT, ?REQ_KIND}, 5000
        ),
        {ok, Second} = gen_server:call(
            Pool, {try_checkout, ?HOST, ?PORT, ?TRANSPORT, ?REQ_KIND}, 5000
        ),
        ?assert(lists:member(First, [PidA, PidB])),
        ?assert(lists:member(Second, [PidA, PidB]))
    end).

open_connection_await_up_error_test() ->
    unload_gun(),
    meck:new(gun, [unstick]),
    FakePid = spawn(fun() -> receive after infinity -> ok end end),
    meck:expect(gun, open, fun(_, _, _) -> {ok, FakePid} end),
    meck:expect(gun, await_up, fun(_, _) -> {error, timeout} end),
    meck:expect(gun, close, fun(_) -> ok end),
    try
        ?assertMatch({error, {await_up, timeout}},
            pertisk_eproxy_upstream_pool:checkout(
                ?HOST, 1, ?TRANSPORT, ?REQ_KIND, ?GUN_OPTS
            ))
    after
        exit(FakePid, kill),
        unload_gun()
    end.

pool_full_drops_extra_registration_test() ->
    with_pool(fun(Pool) ->
        pertisk_eproxy_test_helpers:ensure_config(),
        Base = pertisk_eproxy_config:get_config(),
        ok = pertisk_eproxy_test_helpers:put_config_retry(Base#{upstream_pool_size => 1}, 30),
        try
            Pid1 = fake_conn(),
            Pid2 = fake_conn(),
            gen_server:cast(Pool, {register, ?HOST, ?PORT, ?TRANSPORT, ?REQ_KIND, ?GUN_OPTS, Pid1}),
            gen_server:cast(Pool, {register, ?HOST, ?PORT, ?TRANSPORT, ?REQ_KIND, ?GUN_OPTS, Pid2}),
            timer:sleep(20),
            {ok, Only} = gen_server:call(
                Pool, {try_checkout, ?HOST, ?PORT, ?TRANSPORT, ?REQ_KIND}, 5000
            ),
            ?assertEqual(Pid1, Only)
        after
            ok = pertisk_eproxy_test_helpers:put_config_retry(Base, 30)
        end
    end).

grpc_profile_checkout_test() ->
    with_pool_and_gun(fun(_Pool) ->
        {ok, Pid} = pertisk_eproxy_upstream_pool:checkout(
            ?HOST, ?PORT, ?TRANSPORT, grpc, ?GUN_OPTS
        ),
        ?assert(is_pid(Pid))
    end).

checkout_set_owner_error_closes_connection_test() ->
    with_pool(fun(_Pool) ->
        unload_gun(),
        meck:new(gun, [unstick]),
        FakePid = spawn(fun() -> receive after infinity -> ok end end),
        meck:expect(gun, open, fun(_, _, _) -> {ok, FakePid} end),
        meck:expect(gun, await_up, fun(_, _) -> {ok, http} end),
        meck:expect(gun, set_owner, fun(_, _) -> {error, denied} end),
        meck:expect(gun, close, fun(_) -> ok end),
        try
            ?assertMatch({error, {set_owner, denied}},
                pertisk_eproxy_upstream_pool:checkout(
                    ?HOST, ?PORT, ?TRANSPORT, ?REQ_KIND, ?GUN_OPTS
                ))
        after
            exit(FakePid, kill),
            unload_gun()
        end
    end).

register_dead_pid_is_ignored_test() ->
    with_pool(fun(Pool) ->
        {Dead, Ref} = spawn_monitor(fun() -> ok end),
        receive {'DOWN', Ref, _, _, _} -> ok end,
        gen_server:cast(Pool, {register, ?HOST, ?PORT, ?TRANSPORT, ?REQ_KIND, ?GUN_OPTS, Dead}),
        timer:sleep(20),
        ?assertEqual(
            empty,
            gen_server:call(
                Pool,
                {try_checkout, ?HOST, ?PORT, ?TRANSPORT, ?REQ_KIND},
                5000
            )
        )
    end).

fill_done_clears_filling_flag_test() ->
    with_pool(fun(Pool) ->
        Key = {?HOST, ?PORT, ?TRANSPORT, http},
        sys:replace_state(Pool, fun(#{pools := Pools} = S) ->
            Entry = #{conns => [], rr => 0, filling => true},
            S#{pools => Pools#{Key => Entry}}
        end),
        gen_server:cast(Pool, {fill_done, Key}),
        #{pools := Pools} = sys:get_state(Pool),
        #{filling := false} = maps:get(Key, Pools)
    end).

code_change_passthrough_test() ->
    with_pool(fun(Pool) ->
        State = sys:get_state(Pool),
        ?assertEqual({ok, State}, pertisk_eproxy_upstream_pool:code_change("1", State, []))
    end).

terminate_closes_pool_connections_test() ->
    pertisk_eproxy_test_helpers:ensure_h3_deps(),
    setup_gun_mock(),
    try
        {ok, Pool} = pertisk_eproxy_upstream_pool:start_link(),
        unlink(Pool),
        {ok, _} = pertisk_eproxy_upstream_pool:checkout(
            ?HOST, ?PORT, ?TRANSPORT, ?REQ_KIND, ?GUN_OPTS
        ),
        exit(Pool, shutdown),
        timer:sleep(50),
        ?assertEqual(undefined, whereis(pertisk_eproxy_upstream_pool))
    after
        unload_gun()
    end.

checkout_normalizes_list_host_test() ->
    with_pool_and_gun(fun(_Pool) ->
        {ok, Pid} = pertisk_eproxy_upstream_pool:checkout(
            "127.0.0.1", ?PORT, ?TRANSPORT, ?REQ_KIND, ?GUN_OPTS
        ),
        ?assert(is_pid(Pid))
    end).

with_pool(Fun) ->
    case whereis(pertisk_eproxy_upstream_pool) of
        undefined ->
            {ok, Pool} = pertisk_eproxy_upstream_pool:start_link(),
            try Fun(Pool) after stop_pool(Pool) end;
        Pool ->
            Fun(Pool)
    end.

with_pool_and_gun(Fun) ->
    pertisk_eproxy_test_helpers:ensure_h3_deps(),
    setup_gun_mock(),
    try
        with_pool(Fun)
    after
        unload_gun()
    end.

setup_gun_mock() ->
    unload_gun(),
    meck:new(gun, [unstick]),
    meck:expect(gun, open, fun(_, _, _) ->
        Pid = spawn(fun() ->
            receive
                {'DOWN', _, _, _, _} -> ok;
                _ -> ok
            end
        end),
        {ok, Pid}
    end),
    meck:expect(gun, await_up, fun(_, _) -> {ok, http} end),
    meck:expect(gun, set_owner, fun(_, _) -> ok end),
    meck:expect(gun, close, fun(_) -> ok end),
    ok.

stop_pool(Pid) when is_pid(Pid) ->
    catch gen_server:stop(Pid),
    ok.

unload_gun() ->
    case lists:member(gun, meck:mocked()) of
        true -> meck:unload(gun);
        false -> ok
    end.

fake_conn() ->
    spawn(fun() ->
        receive
            {'DOWN', _, _, _, _} -> ok;
            _ -> ok
        end
    end).
