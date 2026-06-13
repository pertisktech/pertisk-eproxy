-module(pertisk_ingress_leader_tests).

-include_lib("eunit/include/eunit.hrl").

stop_leader() ->
    case whereis(pertisk_ingress_leader) of
        undefined -> ok;
        Pid -> pertisk_eproxy_test_helpers:safe_gen_server_stop(Pid)
    end.

with_env(Key, Val, Fun) ->
    Old = os:getenv(Key),
    case Val of
        unset -> os:unsetenv(Key);
        {set, NewVal} -> os:putenv(Key, NewVal)
    end,
    try Fun() after
        case Old of
            false -> os:unsetenv(Key);
            OldVal -> os:putenv(Key, OldVal)
        end
    end.

with_leader_env(Expects, Fun) ->
    pertisk_eproxy_test_helpers:ignoring_errors(fun() -> pertisk_eproxy_test_helpers:unload_mocks([pertisk_ingress_env]) end),
    meck:new(pertisk_ingress_env, [unstick, passthrough]),
    maps:fold(
        fun(K, V, _) -> meck:expect(pertisk_ingress_env, K, fun() -> V end) end,
        ok,
        Expects
    ),
    try Fun() after pertisk_eproxy_test_helpers:unload_mocks([pertisk_ingress_env]) end.

lease_now() ->
    {{Y, Mo, D}, {H, Mi, S}} = calendar:universal_time(),
    list_to_binary(
        io_lib:format("~4..0w-~2..0w-~2..0wT~2..0w:~2..0w:~2..0wZ", [Y, Mo, D, H, Mi, S])
    ).

expired_renew_time(Dur) ->
    Sec = erlang:system_time(second) - Dur - 60,
    calendar:system_time_to_rfc3339(Sec, [{unit, second}]).

is_leader_when_not_running_test() ->
    stop_leader(),
    ?assert(pertisk_ingress_leader:is_leader()).

leader_disabled_test() ->
    stop_leader(),
    ok = pertisk_ingress_status:init(),
    with_leader_env(#{leader_election_enabled => false}, fun() ->
        {ok, Pid} = pertisk_ingress_leader:start_link(),
        ?assert(pertisk_ingress_leader:is_leader()),
        ?assertEqual({error, unknown}, gen_server:call(Pid, unknown)),
        gen_server:stop(Pid)
    end),
    stop_leader().

leader_ekub_init_failure_test() ->
    stop_leader(),
    ok = pertisk_ingress_status:init(),
    meck:new(pertisk_ingress_ekub, [unstick]),
    meck:expect(pertisk_ingress_ekub, init, fun() -> {error, denied} end),
    with_leader_env(#{leader_election_enabled => true}, fun() ->
        {ok, Pid} = pertisk_ingress_leader:start_link(),
        ?assert(pertisk_ingress_leader:is_leader()),
        gen_server:stop(Pid)
    end),
    pertisk_eproxy_test_helpers:unload_mocks([pertisk_ingress_ekub]),
    stop_leader().

leader_create_lease_test() ->
    stop_leader(),
    ok = pertisk_ingress_status:init(),
    Conn = mock_conn,
    meck:new(pertisk_ingress_ekub, [unstick]),
    meck:expect(pertisk_ingress_ekub, init, fun() -> {ok, Conn} end),
    meck:new(ekub, [unstick]),
    meck:expect(ekub, read, fun(lease, _Ns, _Name, _MockConn) ->
        {error, #{<<"code">> => 404}}
    end),
    meck:expect(ekub, create, fun(_Lease, _Ns, _MockConn) -> {ok, #{}} end),
    with_leader_env(#{
        leader_election_enabled => true,
        leader_namespace => <<"default">>,
        leader_lease_name => <<"test-lease">>,
        holder_id => <<"holder-a">>,
        lease_duration_seconds => 15,
        renew_interval_seconds => 1
    }, fun() ->
        {ok, Pid} = pertisk_ingress_leader:start_link(),
        timer:sleep(50),
        Pid ! renew,
        timer:sleep(50),
        ?assert(pertisk_ingress_leader:is_leader()),
        gen_server:stop(Pid)
    end),
    pertisk_eproxy_test_helpers:unload_mocks([ekub, pertisk_ingress_ekub]),
    stop_leader().

leader_renew_existing_owner_test() ->
    stop_leader(),
    ok = pertisk_ingress_status:init(),
    Conn = mock_conn,
    Holder = <<"holder-b">>,
    Lease = #{
        <<"spec">> => #{
            <<"holderIdentity">> => Holder,
            <<"renewTime">> => lease_now(),
            <<"leaseDurationSeconds">> => 15,
            <<"acquireTime">> => lease_now()
        }
    },
    meck:new(pertisk_ingress_ekub, [unstick]),
    meck:expect(pertisk_ingress_ekub, init, fun() -> {ok, Conn} end),
    meck:new(ekub, [unstick]),
    meck:expect(ekub, read, fun(lease, _A, _B, _MockConn) -> {ok, Lease} end),
    meck:expect(ekub, replace, fun(_L, _Ns, _MockConn) -> {ok, #{}} end),
    with_leader_env(#{
        leader_election_enabled => true,
        leader_namespace => <<"default">>,
        leader_lease_name => <<"test-lease">>,
        holder_id => Holder,
        lease_duration_seconds => 15,
        renew_interval_seconds => 1
    }, fun() ->
        {ok, Pid} = pertisk_ingress_leader:start_link(),
        Pid ! renew,
        timer:sleep(50),
        ?assert(pertisk_ingress_leader:is_leader()),
        gen_server:stop(Pid)
    end),
    pertisk_eproxy_test_helpers:unload_mocks([ekub, pertisk_ingress_ekub]),
    stop_leader().

leader_not_owner_unexpired_test() ->
    stop_leader(),
    ok = pertisk_ingress_status:init(),
    Conn = mock_conn,
    Lease = #{
        <<"spec">> => #{
            <<"holderIdentity">> => <<"other">>,
            <<"renewTime">> => lease_now(),
            <<"leaseDurationSeconds">> => 15
        }
    },
    meck:new(pertisk_ingress_ekub, [unstick]),
    meck:expect(pertisk_ingress_ekub, init, fun() -> {ok, Conn} end),
    meck:new(ekub, [unstick]),
    meck:expect(ekub, read, fun(lease, _A, _B, _MockConn) -> {ok, Lease} end),
    with_leader_env(#{
        leader_election_enabled => true,
        leader_namespace => <<"default">>,
        leader_lease_name => <<"test-lease">>,
        holder_id => <<"holder-c">>,
        lease_duration_seconds => 15,
        renew_interval_seconds => 1
    }, fun() ->
        {ok, Pid} = pertisk_ingress_leader:start_link(),
        Pid ! renew,
        timer:sleep(50),
        ?assertNot(pertisk_ingress_leader:is_leader()),
        gen_server:stop(Pid)
    end),
    pertisk_eproxy_test_helpers:unload_mocks([ekub, pertisk_ingress_ekub]),
    stop_leader().

leader_take_expired_lease_test() ->
    stop_leader(),
    ok = pertisk_ingress_status:init(),
    Conn = mock_conn,
    Holder = <<"holder-d">>,
    Lease = #{
        <<"spec">> => #{
            <<"holderIdentity">> => <<"other">>,
            <<"renewTime">> => list_to_binary(expired_renew_time(15)),
            <<"leaseDurationSeconds">> => 15
        }
    },
    meck:new(pertisk_ingress_ekub, [unstick]),
    meck:expect(pertisk_ingress_ekub, init, fun() -> {ok, Conn} end),
    meck:new(ekub, [unstick]),
    meck:expect(ekub, read, fun(lease, _A, _B, _MockConn) -> {ok, Lease} end),
    meck:expect(ekub, replace, fun(_L, _Ns, _MockConn) -> {ok, #{}} end),
    with_leader_env(#{
        leader_election_enabled => true,
        leader_namespace => <<"default">>,
        leader_lease_name => <<"test-lease">>,
        holder_id => Holder,
        lease_duration_seconds => 15,
        renew_interval_seconds => 1
    }, fun() ->
        {ok, Pid} = pertisk_ingress_leader:start_link(),
        Pid ! renew,
        timer:sleep(50),
        ?assert(pertisk_ingress_leader:is_leader()),
        gen_server:stop(Pid)
    end),
    pertisk_eproxy_test_helpers:unload_mocks([ekub, pertisk_ingress_ekub]),
    stop_leader().

leader_list_fallback_create_test() ->
    stop_leader(),
    ok = pertisk_ingress_status:init(),
    Conn = mock_conn,
    meck:new(pertisk_ingress_ekub, [unstick]),
    meck:expect(pertisk_ingress_ekub, init, fun() -> {ok, Conn} end),
    meck:new(ekub, [unstick]),
    meck:expect(ekub, read, fun(lease, _Ns, _Name, mock_conn) ->
        {error, #{<<"reason">> => <<"Forbidden">>}}
    end),
    meck:expect(ekub, read, fun(lease, _Query, mock_conn) ->
        {ok, #{<<"items">> => []}}
    end),
    meck:expect(ekub, create, fun(_Lease, _Ns, mock_conn) ->
        {error, #{<<"code">> => 409}}
    end),
    with_leader_env(#{
        leader_election_enabled => true,
        leader_namespace => <<"default">>,
        leader_lease_name => <<"test-lease">>,
        holder_id => <<"holder-e">>,
        lease_duration_seconds => 15,
        renew_interval_seconds => 1
    }, fun() ->
        {ok, Pid} = pertisk_ingress_leader:start_link(),
        Pid ! renew,
        timer:sleep(50),
        ?assertNot(pertisk_ingress_leader:is_leader()),
        gen_server:stop(Pid)
    end),
    pertisk_eproxy_test_helpers:unload_mocks([ekub, pertisk_ingress_ekub]),
    stop_leader().

leader_renew_disabled_state_test() ->
    stop_leader(),
    ok = pertisk_ingress_status:init(),
    with_leader_env(#{leader_election_enabled => false}, fun() ->
        {ok, Pid} = pertisk_ingress_leader:start_link(),
        Pid ! renew,
        ?assert(pertisk_ingress_leader:is_leader()),
        gen_server:stop(Pid)
    end),
    stop_leader().

leader_renew_api_error_keeps_state_test() ->
    stop_leader(),
    ok = pertisk_ingress_status:init(),
    Conn = mock_conn,
    Holder = <<"holder-f">>,
    Lease = #{
        <<"spec">> => #{
            <<"holderIdentity">> => Holder,
            <<"renewTime">> => lease_now(),
            <<"leaseDurationSeconds">> => 15,
            <<"acquireTime">> => lease_now()
        }
    },
    pertisk_eproxy_test_helpers:ignoring_errors(fun() -> pertisk_eproxy_test_helpers:unload_mocks([pertisk_ingress_ekub]) end),
    pertisk_eproxy_test_helpers:ignoring_errors(fun() -> pertisk_eproxy_test_helpers:unload_mocks([ekub]) end),
    meck:new(pertisk_ingress_ekub, [unstick]),
    meck:expect(pertisk_ingress_ekub, init, fun() -> {ok, Conn} end),
    meck:new(ekub, [unstick]),
    meck:expect(ekub, read, fun(lease, _A, _B, _Conn) -> {ok, Lease} end),
    meck:expect(ekub, replace, fun(_L, _Ns, _Conn) -> {error, #{<<"code">> => 500}} end),
    with_leader_env(#{
        leader_election_enabled => true,
        leader_namespace => <<"default">>,
        leader_lease_name => <<"test-lease">>,
        holder_id => Holder,
        lease_duration_seconds => 15,
        renew_interval_seconds => 1
    }, fun() ->
        {ok, Pid} = pertisk_ingress_leader:start_link(),
        Pid ! renew,
        timer:sleep(50),
        ?assertNot(pertisk_ingress_leader:is_leader()),
        gen_server:stop(Pid)
    end),
    pertisk_eproxy_test_helpers:unload_mocks([ekub, pertisk_ingress_ekub]),
    stop_leader().

leader_create_non_conflict_error_test() ->
    stop_leader(),
    ok = pertisk_ingress_status:init(),
    Conn = mock_conn,
    pertisk_eproxy_test_helpers:ignoring_errors(fun() -> pertisk_eproxy_test_helpers:unload_mocks([pertisk_ingress_ekub]) end),
    pertisk_eproxy_test_helpers:ignoring_errors(fun() -> pertisk_eproxy_test_helpers:unload_mocks([ekub]) end),
    meck:new(pertisk_ingress_ekub, [unstick]),
    meck:expect(pertisk_ingress_ekub, init, fun() -> {ok, Conn} end),
    meck:new(ekub, [unstick]),
    meck:expect(ekub, read, fun(lease, _Ns, _Name, _Conn) -> {error, #{<<"code">> => 404}} end),
    meck:expect(ekub, create, fun(_Lease, _Ns, _Conn) -> {error, #{<<"code">> => 500}} end),
    with_leader_env(#{
        leader_election_enabled => true,
        leader_namespace => <<"default">>,
        leader_lease_name => <<"test-lease">>,
        holder_id => <<"holder-g">>,
        lease_duration_seconds => 15,
        renew_interval_seconds => 1
    }, fun() ->
        {ok, Pid} = pertisk_ingress_leader:start_link(),
        Pid ! renew,
        timer:sleep(50),
        ?assertNot(pertisk_ingress_leader:is_leader()),
        gen_server:stop(Pid)
    end),
    pertisk_eproxy_test_helpers:unload_mocks([ekub, pertisk_ingress_ekub]),
    stop_leader().

leader_handle_info_other_test() ->
    stop_leader(),
    ok = pertisk_ingress_status:init(),
    with_leader_env(#{leader_election_enabled => false}, fun() ->
        {ok, Pid} = pertisk_ingress_leader:start_link(),
        Pid ! other_message,
        ?assert(pertisk_ingress_leader:is_leader()),
        gen_server:stop(Pid)
    end),
    stop_leader().
