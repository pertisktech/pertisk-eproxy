-module(pertisk_eproxy_lb_tests).

-include_lib("eunit/include/eunit.hrl").

%% ---------------------------------------------------------------------------
%% Helpers
%% ---------------------------------------------------------------------------

healthy_upstream(Addr) ->
    healthy_upstream(Addr, 1).

healthy_upstream(Addr, Weight) ->
    #{addr => Addr, weight => Weight, healthy => true, conns => 0}.

unhealthy_upstream(Addr) ->
    #{addr => Addr, weight => 1, healthy => false, conns => 0}.

healthy_upstream_with_conns(Addr, Conns) ->
    #{addr => Addr, weight => 1, healthy => true, conns => Conns}.

basic_state(Algo, Upstreams) ->
    #{algorithm => Algo, upstreams => Upstreams, rr_index => 0}.

%% ---------------------------------------------------------------------------
%% round_robin
%% ---------------------------------------------------------------------------

round_robin_single_upstream_test() ->
    U = healthy_upstream(<<"127.0.0.1:8080">>),
    State = basic_state(round_robin, [U]),
    {ok, Selected, _} = pertisk_eproxy_lb:next(State, round_robin, undefined),
    ?assertEqual(<<"127.0.0.1:8080">>, maps:get(addr, Selected)).

round_robin_rotates_correctly_test() ->
    U1 = healthy_upstream(<<"127.0.0.1:8081">>),
    U2 = healthy_upstream(<<"127.0.0.1:8082">>),
    U3 = healthy_upstream(<<"127.0.0.1:8083">>),
    State0 = basic_state(round_robin, [U1, U2, U3]),

    {ok, Sel1, State1} = pertisk_eproxy_lb:next(State0, round_robin, undefined),
    {ok, Sel2, State2} = pertisk_eproxy_lb:next(State1, round_robin, undefined),
    {ok, Sel3, State3} = pertisk_eproxy_lb:next(State2, round_robin, undefined),

    ?assertEqual(<<"127.0.0.1:8081">>, maps:get(addr, Sel1)),
    ?assertEqual(<<"127.0.0.1:8082">>, maps:get(addr, Sel2)),
    ?assertEqual(<<"127.0.0.1:8083">>, maps:get(addr, Sel3)),

    %% Should wrap back to first
    {ok, Sel4, _State4} = pertisk_eproxy_lb:next(State3, round_robin, undefined),
    ?assertEqual(<<"127.0.0.1:8081">>, maps:get(addr, Sel4)).

round_robin_skips_unhealthy_test() ->
    U1 = unhealthy_upstream(<<"127.0.0.1:8081">>),
    U2 = healthy_upstream(<<"127.0.0.1:8082">>),
    U3 = healthy_upstream(<<"127.0.0.1:8083">>),
    State = basic_state(round_robin, [U1, U2, U3]),
    {ok, Selected, _} = pertisk_eproxy_lb:next(State, round_robin, undefined),
    ?assertEqual(<<"127.0.0.1:8082">>, maps:get(addr, Selected)).

round_robin_all_unhealthy_test() ->
    U1 = unhealthy_upstream(<<"127.0.0.1:8081">>),
    U2 = unhealthy_upstream(<<"127.0.0.1:8082">>),
    State = basic_state(round_robin, [U1, U2]),
    ?assertEqual(
        {error, no_healthy_upstream},
        pertisk_eproxy_lb:next(State, round_robin, undefined)
    ).

round_robin_empty_upstreams_test() ->
    State = basic_state(round_robin, []),
    ?assertEqual(
        {error, no_healthy_upstream},
        pertisk_eproxy_lb:next(State, round_robin, undefined)
    ).

%% ---------------------------------------------------------------------------
%% least_connections
%% ---------------------------------------------------------------------------

least_connections_picks_lowest_test() ->
    U1 = healthy_upstream_with_conns(<<"127.0.0.1:8081">>, 5),
    U2 = healthy_upstream_with_conns(<<"127.0.0.1:8082">>, 2),
    U3 = healthy_upstream_with_conns(<<"127.0.0.1:8083">>, 8),
    State = basic_state(least_connections, [U1, U2, U3]),
    {ok, Selected, _} = pertisk_eproxy_lb:next(State, least_connections, undefined),
    ?assertEqual(<<"127.0.0.1:8082">>, maps:get(addr, Selected)).

least_connections_single_upstream_test() ->
    U = healthy_upstream_with_conns(<<"127.0.0.1:8080">>, 10),
    State = basic_state(least_connections, [U]),
    {ok, Selected, _} = pertisk_eproxy_lb:next(State, least_connections, undefined),
    ?assertEqual(<<"127.0.0.1:8080">>, maps:get(addr, Selected)).

least_connections_skips_unhealthy_test() ->
    U1 = unhealthy_upstream(<<"127.0.0.1:8081">>),
    U2 = healthy_upstream_with_conns(<<"127.0.0.1:8082">>, 3),
    State = basic_state(least_connections, [U1, U2]),
    {ok, Selected, _} = pertisk_eproxy_lb:next(State, least_connections, undefined),
    ?assertEqual(<<"127.0.0.1:8082">>, maps:get(addr, Selected)).

least_connections_all_unhealthy_test() ->
    U1 = unhealthy_upstream(<<"127.0.0.1:8081">>),
    U2 = unhealthy_upstream(<<"127.0.0.1:8082">>),
    State = basic_state(least_connections, [U1, U2]),
    ?assertEqual(
        {error, no_healthy_upstream},
        pertisk_eproxy_lb:next(State, least_connections, undefined)
    ).

least_connections_same_conns_picks_first_test() ->
    U1 = healthy_upstream_with_conns(<<"127.0.0.1:8081">>, 1),
    U2 = healthy_upstream_with_conns(<<"127.0.0.1:8082">>, 1),
    State = basic_state(least_connections, [U1, U2]),
    {ok, Selected, _} = pertisk_eproxy_lb:next(State, least_connections, undefined),
    ?assertEqual(<<"127.0.0.1:8081">>, maps:get(addr, Selected)).

least_connections_preserves_rr_index_test() ->
    U1 = healthy_upstream_with_conns(<<"127.0.0.1:8081">>, 0),
    U2 = healthy_upstream_with_conns(<<"127.0.0.1:8082">>, 0),
    State = #{algorithm => least_connections, upstreams => [U1, U2], rr_index => 42},
    {ok, _Selected, NewState} = pertisk_eproxy_lb:next(State, least_connections, undefined),
    ?assertEqual(42, maps:get(rr_index, NewState)).

%% ---------------------------------------------------------------------------
%% ip_hash
%% ---------------------------------------------------------------------------

ip_hash_same_ip_returns_same_upstream_test() ->
    U1 = healthy_upstream(<<"127.0.0.1:8081">>),
    U2 = healthy_upstream(<<"127.0.0.1:8082">>),
    U3 = healthy_upstream(<<"127.0.0.1:8083">>),
    State0 = basic_state(ip_hash, [U1, U2, U3]),
    ClientIp = <<"10.0.0.5">>,

    {ok, Sel1, _} = pertisk_eproxy_lb:next(State0, ip_hash, ClientIp),
    {ok, Sel2, _} = pertisk_eproxy_lb:next(State0, ip_hash, ClientIp),

    ?assertEqual(maps:get(addr, Sel1), maps:get(addr, Sel2)).

ip_hash_single_upstream_test() ->
    U = healthy_upstream(<<"127.0.0.1:8080">>),
    State = basic_state(ip_hash, [U]),
    {ok, Selected, _} = pertisk_eproxy_lb:next(State, ip_hash, <<"1.2.3.4">>),
    ?assertEqual(<<"127.0.0.1:8080">>, maps:get(addr, Selected)).

ip_hash_undefined_ip_test() ->
    U1 = healthy_upstream(<<"127.0.0.1:8081">>),
    U2 = healthy_upstream(<<"127.0.0.1:8082">>),
    State = basic_state(ip_hash, [U1, U2]),
    {ok, Selected, _} = pertisk_eproxy_lb:next(State, ip_hash, undefined),
    ?assert(is_binary(maps:get(addr, Selected))).

ip_hash_skips_unhealthy_test() ->
    U1 = unhealthy_upstream(<<"127.0.0.1:8081">>),
    U2 = healthy_upstream(<<"127.0.0.1:8082">>),
    State = basic_state(ip_hash, [U1, U2]),
    {ok, Selected, _} = pertisk_eproxy_lb:next(State, ip_hash, <<"10.0.0.1">>),
    ?assertEqual(<<"127.0.0.1:8082">>, maps:get(addr, Selected)).

ip_hash_all_unhealthy_test() ->
    U1 = unhealthy_upstream(<<"127.0.0.1:8081">>),
    State = basic_state(ip_hash, [U1]),
    ?assertEqual(
        {error, no_healthy_upstream},
        pertisk_eproxy_lb:next(State, ip_hash, <<"10.0.0.1">>)
    ).

ip_hash_different_ips_may_differ_test() ->
    U1 = healthy_upstream(<<"127.0.0.1:8081">>),
    U2 = healthy_upstream(<<"127.0.0.1:8082">>),
    State = basic_state(ip_hash, [U1, U2]),
    {ok, _Selected, _} = pertisk_eproxy_lb:next(State, ip_hash, <<"10.0.0.1">>),
    %% No assertion on which upstream — just checking no crash
    ?assert(true).

ip_hash_preserves_rr_index_test() ->
    U1 = healthy_upstream(<<"127.0.0.1:8081">>),
    U2 = healthy_upstream(<<"127.0.0.1:8082">>),
    State = #{algorithm => ip_hash, upstreams => [U1, U2], rr_index => 99},
    {ok, _Selected, NewState} = pertisk_eproxy_lb:next(State, ip_hash, <<"10.0.0.1">>),
    ?assertEqual(99, maps:get(rr_index, NewState)).

%% ---------------------------------------------------------------------------
%% ip_hash_index/2
%% ---------------------------------------------------------------------------

ip_hash_index_returns_valid_range_test() ->
    lists:foreach(
        fun(N) ->
            Idx = pertisk_eproxy_lb:ip_hash_index(<<"10.0.0.1">>, N),
            ?assert(Idx >= 0),
            ?assert(Idx < N)
        end,
        [1, 2, 3, 5, 10, 100]
    ).

ip_hash_index_same_ip_same_result_test() ->
    R1 = pertisk_eproxy_lb:ip_hash_index(<<"192.168.1.1">>, 100),
    R2 = pertisk_eproxy_lb:ip_hash_index(<<"192.168.1.1">>, 100),
    ?assertEqual(R1, R2).

ip_hash_index_undefined_returns_valid_test() ->
    Idx = pertisk_eproxy_lb:ip_hash_index(undefined, 5),
    ?assert(Idx >= 0),
    ?assert(Idx < 5).

%% ---------------------------------------------------------------------------
%% State update after selection
%% ---------------------------------------------------------------------------

next_preserves_upstreams_test() ->
    U1 = healthy_upstream(<<"127.0.0.1:8081">>),
    U2 = healthy_upstream(<<"127.0.0.1:8082">>),
    State = basic_state(round_robin, [U1, U2]),
    {ok, _Selected, NewState} = pertisk_eproxy_lb:next(State, round_robin, undefined),
    NewUpstreams = maps:get(upstreams, NewState),
    ?assertEqual([U1, U2], NewUpstreams).

%% ---------------------------------------------------------------------------
%% Algo override from next/3 vs state
%% ---------------------------------------------------------------------------

next_uses_state_algorithm_when_present_test() ->
    U1 = healthy_upstream_with_conns(<<"127.0.0.1:8081">>, 10),
    U2 = healthy_upstream_with_conns(<<"127.0.0.1:8082">>, 1),
    State = #{algorithm => least_connections, upstreams => [U1, U2], rr_index => 0},
    {ok, Selected, _} = pertisk_eproxy_lb:next(State, round_robin, undefined),
    %% Should use least_connections (from state), not round_robin (override arg)
    ?assertEqual(<<"127.0.0.1:8082">>, maps:get(addr, Selected)).

next_falls_back_to_algo_override_when_state_missing_test() ->
    U1 = healthy_upstream_with_conns(<<"127.0.0.1:8081">>, 10),
    U2 = healthy_upstream_with_conns(<<"127.0.0.1:8082">>, 1),
    State = #{upstreams => [U1, U2], rr_index => 0},
    {ok, Selected, _} = pertisk_eproxy_lb:next(State, least_connections, undefined),
    ?assertEqual(<<"127.0.0.1:8082">>, maps:get(addr, Selected)).