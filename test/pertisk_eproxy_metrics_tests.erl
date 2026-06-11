-module(pertisk_eproxy_metrics_tests).

-include_lib("eunit/include/eunit.hrl").

setup() ->
    pertisk_eproxy_test_helpers:ensure_metrics().

inc_request_test() ->
    setup(),
    ?assertEqual(ok, pertisk_eproxy_metrics:inc_request(<<"host">>, <<"200">>, <<"h3">>)).

inc_site_request_test() ->
    setup(),
    ?assertEqual(ok, pertisk_eproxy_metrics:inc_site_request(<<"site">>, <<"200">>, <<"grpc">>)).

record_proxy_bytes_test() ->
    setup(),
    ?assertEqual(ok, pertisk_eproxy_metrics:record_proxy_bytes(<<"host">>, 10, 20)).

record_site_bytes_test() ->
    setup(),
    ?assertEqual(ok, pertisk_eproxy_metrics:record_site_bytes(<<"site">>, 5, 15)).

observe_duration_test() ->
    setup(),
    ?assertEqual(ok, pertisk_eproxy_metrics:observe_duration(<<"host">>, 42)).

metrics_gen_server_start_link_test() ->
    setup(),
    case whereis(pertisk_eproxy_metrics) of
        undefined ->
            {ok, Pid} = pertisk_eproxy_metrics:start_link(),
            ?assert(is_pid(Pid));
        Pid ->
            ?assert(is_pid(Pid))
    end.

set_upstream_conn_test() ->
    setup(),
    ?assertEqual(ok, pertisk_eproxy_metrics:set_upstream_conn(<<"web">>, <<"10.0.0.1:80">>, 2)).

set_upstream_conns_test() ->
    setup(),
    Ups = [{<<"10.0.0.1:80">>, 1}, {<<"10.0.0.2:80">>, 0}],
    ?assertEqual(ok, pertisk_eproxy_metrics:set_upstream_conns(<<"web">>, Ups)).

set_upstream_healthy_test() ->
    setup(),
    Health = [{<<"10.0.0.1:80">>, true}, {<<"10.0.0.2:80">>, false}],
    ?assertEqual(ok, pertisk_eproxy_metrics:set_upstream_healthy(<<"web">>, Health)).

observe_duration_with_site_test() ->
    setup(),
    ?assertEqual(ok, pertisk_eproxy_metrics:observe_duration(<<"host">>, <<"site">>, 99)).

record_proxy_bytes_zero_skips_inc_test() ->
    setup(),
    ?assertEqual(ok, pertisk_eproxy_metrics:record_proxy_bytes(<<"host">>, 0, 0)).

metrics_update_upstream_metrics_info_test() ->
    setup(),
    pertisk_eproxy_test_helpers:ensure_config(),
    Backend = #{
        name => <<"metrics-web">>,
        algorithm => round_robin,
        upstreams => [#{addr => <<"127.0.0.1:8080">>, weight => 1}]
    },
    BaseBackends = pertisk_eproxy_config:get_backends(),
    ok = pertisk_eproxy_config:sync_ingress([], [Backend]),
    meck:new(pertisk_eproxy_backend, [unstick, passthrough]),
    meck:expect(pertisk_eproxy_backend, status, fun(<<"metrics-web">>) ->
        {ok, #{
            upstreams => [
                #{addr => <<"127.0.0.1:8080">>, conns => 2, healthy => true}
            ]
        }}
    end),
    try
        Pid = whereis(pertisk_eproxy_metrics),
        ?assert(is_pid(Pid)),
        Pid ! update_upstream_metrics,
        receive after 200 -> ok end,
        ?assertEqual(
            ok,
            pertisk_eproxy_metrics:set_upstream_conns(
                <<"metrics-web">>, [{<<"127.0.0.1:8080">>, 2}]
            )
        )
    after
        meck:unload(pertisk_eproxy_backend),
        pertisk_eproxy_config:sync_ingress([], BaseBackends)
    end.
