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
