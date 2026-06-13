-module(pertisk_eproxy_stats_tests).

-include_lib("eunit/include/eunit.hrl").

snapshot_returns_map_test() ->
    with_metrics(fun() ->
        S = pertisk_eproxy_stats:snapshot(),
        ?assert(map_has_key(<<"h2_requests_total">>, S)),
        ?assert(map_has_key(<<"h3_requests_total">>, S)),
        ?assert(map_has_key(<<"uptime_secs">>, S))
    end).

snapshot_aggregates_protocol_counters_test() ->
    with_metrics(fun() ->
        B0 = pertisk_eproxy_stats:snapshot(),
        pertisk_eproxy_metrics:inc_request(<<"a.example">>, <<"200">>, <<"http1">>),
        pertisk_eproxy_metrics:inc_request(<<"a.example">>, <<"200">>, <<"admin">>),
        pertisk_eproxy_metrics:inc_request(<<"a.example">>, <<"200">>, <<"tls_h1">>),
        pertisk_eproxy_metrics:inc_request(<<"a.example">>, <<"200">>, <<"h2">>),
        pertisk_eproxy_metrics:inc_request(<<"b.example">>, <<"200">>, <<"h3">>),
        pertisk_eproxy_metrics:inc_request(<<"c.example">>, <<"200">>, <<"grpc">>),
        pertisk_eproxy_metrics:inc_site_request(<<"site-a">>, <<"200">>, <<"h2">>),
        pertisk_eproxy_metrics:record_proxy_bytes(<<"a.example">>, 100, 200),
        pertisk_eproxy_metrics:record_site_bytes(<<"site-a">>, 50, 75),
        pertisk_eproxy_metrics:set_upstream_conn(<<"be">>, <<"up1">>, 2),
        B1 = pertisk_eproxy_stats:snapshot(),
        ?assertEqual(2, diff(B1, B0, <<"http_requests_total">>)),
        ?assertEqual(1, diff(B1, B0, <<"management_requests_total">>)),
        ?assertEqual(2, diff(B1, B0, <<"https_requests_total">>)),
        ?assertEqual(1, diff(B1, B0, <<"h2_requests_total">>)),
        ?assertEqual(1, diff(B1, B0, <<"h3_requests_total">>)),
        ?assertEqual(1, diff(B1, B0, <<"grpc_requests_total">>)),
        ?assertEqual(100, diff(B1, B0, <<"bytes_received_total">>)),
        ?assertEqual(200, diff(B1, B0, <<"bytes_sent_total">>)),
        Conn0 = maps:get(<<"connections_per_site">>, B0, #{}),
        Conn1 = maps:get(<<"connections_per_site">>, B1, #{}),
        ?assert(maps:get(<<"a.example">>, Conn1, 0) - maps:get(<<"a.example">>, Conn0, 0) >= 2)
    end).

snapshot_h3_ratio_zero_when_no_h2_test() ->
    with_metrics(fun() ->
        B0 = pertisk_eproxy_stats:snapshot(),
        case maps:get(<<"h2_requests_total">>, B0) of
            0 ->
                pertisk_eproxy_metrics:inc_request(<<"z.example">>, <<"200">>, <<"h3">>),
                B1 = pertisk_eproxy_stats:snapshot(),
                ?assertEqual(0.0, maps:get(<<"h3_vs_h2_ratio">>, B1));
            _ ->
                ok
        end
    end).

snapshot_with_access_log_and_string_labels_test() ->
    with_metrics(fun() ->
        case whereis(pertisk_eproxy_access_log) of
            undefined ->
                application:ensure_all_started(lager),
                {ok, _} = pertisk_eproxy_access_log:start_link();
            _ ->
                ok
        end,
        prometheus_counter:inc(
            pertisk_eproxy_requests_total,
            ["str-host.example", "200", "http1"]
        ),
        prometheus_counter:inc(
            pertisk_eproxy_site_requests_total,
            ["str-site", "200", "h2"]
        ),
        prometheus_counter:inc(
            pertisk_eproxy_site_bytes_received_total,
            ["str-site"],
            10
        ),
        prometheus_counter:inc(
            pertisk_eproxy_site_bytes_sent_total,
            ["str-site"],
            20
        ),
        S = pertisk_eproxy_stats:snapshot(),
        ?assert(is_integer(maps:get(<<"log_entries">>, S))),
        ?assert(maps:is_key(<<"site_bytes_received_total">>, S)),
        Conn = maps:get(<<"connections_per_site">>, S),
        ?assert(maps:is_key(<<"str-host.example">>, Conn))
    end).

snapshot_connections_per_host_catch_test() ->
    with_metrics(fun() ->
        with_counter_values_throw(pertisk_eproxy_requests_total, fun() ->
            ?assertEqual(
                #{},
                maps:get(<<"connections_per_site">>, pertisk_eproxy_stats:snapshot())
            )
        end)
    end).

snapshot_sum_counter_catch_test() ->
    with_metrics(fun() ->
        with_counter_values_throw(pertisk_eproxy_bytes_sent_total, fun() ->
            Snap = pertisk_eproxy_stats:snapshot(),
            ?assertEqual(0, maps:get(<<"bytes_sent_total">>, Snap))
        end)
    end).

snapshot_sum_gauge_catch_test() ->
    with_metrics(fun() ->
        meck:new(prometheus_gauge, [unstick, passthrough]),
        meck:expect(prometheus_gauge, values, fun(_, _) -> throw(gauge_failed) end),
        try
            Snap = pertisk_eproxy_stats:snapshot(),
            ?assertEqual(0, maps:get(<<"active_connections">>, Snap))
        after
            case lists:member(prometheus_gauge, meck:mocked()) of
                true -> pertisk_eproxy_test_helpers:unload_mocks([prometheus_gauge]);
                false -> ok
            end
        end
    end).

with_counter_values_throw(Metric, Fun) ->
    unload_prometheus_meck(),
    meck:new(prometheus_counter, [unstick, passthrough]),
    meck:expect(prometheus_counter, values, fun
        (default, Metric) -> throw(values_failed);
        (Reg, Name) -> meck:passthrough([Reg, Name])
    end),
    try
        Fun()
    after
        unload_prometheus_meck()
    end.

snapshot_site_ratio_map_test() ->
    with_metrics(fun() ->
        HostX = unique_host(<<"x.example">>),
        HostY = unique_host(<<"y.example">>),
        prometheus_counter:inc(pertisk_eproxy_requests_total, [HostX, <<"200">>, <<"h2">>]),
        prometheus_counter:inc(pertisk_eproxy_requests_total, [HostX, <<"200">>, <<"h3">>]),
        prometheus_counter:inc(pertisk_eproxy_requests_total, [HostY, <<"200">>, <<"h3">>]),
        S = pertisk_eproxy_stats:snapshot(),
        Ratios = maps:get(<<"site_h3_vs_h2_ratio">>, S),
        ?assertEqual(1.0, maps:get(HostX, Ratios)),
        ?assertEqual(0.0, maps:get(HostY, Ratios))
    end).

with_metrics(Fun) ->
    application:ensure_all_started(prometheus),
    pertisk_eproxy_metrics:setup(),
    try
        Fun()
    after
        unload_prometheus_meck(),
        case lists:member(prometheus_gauge, meck:mocked()) of
            true -> pertisk_eproxy_test_helpers:unload_mocks([prometheus_gauge]);
            false -> ok
        end
    end.

diff(After, Before, Key) ->
    maps:get(Key, After) - maps:get(Key, Before).

unique_host(Prefix) ->
    <<Prefix/binary, (integer_to_binary(erlang:unique_integer([positive])))/binary>>.

map_has_key(K, Map) ->
    maps:is_key(K, Map).

unload_prometheus_meck() ->
    case lists:member(prometheus_counter, meck:mocked()) of
        true -> pertisk_eproxy_test_helpers:unload_mocks([prometheus_counter]);
        false -> ok
    end.
