-module(pertisk_eproxy_metrics_tests).

-include_lib("eunit/include/eunit.hrl").

setup_declares_metrics_test() ->
    application:ensure_all_started(prometheus),
    ?assertEqual(ok, pertisk_eproxy_metrics:setup()),
    pertisk_eproxy_metrics:inc_request(<<"example.com">>, <<"200">>, <<"h2">>),
    pertisk_eproxy_metrics:inc_site_request(<<"example.com">>, <<"200">>, <<"h3">>),
    pertisk_eproxy_metrics:observe_duration(<<"example.com">>, 12),
    pertisk_eproxy_metrics:record_proxy_bytes(<<"example.com">>, 100, 50),
    pertisk_eproxy_metrics:record_site_bytes(<<"example.com">>, 100, 50),
    pertisk_eproxy_metrics:set_upstream_conn(<<"web">>, <<"127.0.0.1:8080">>, 2),
    pertisk_eproxy_metrics:set_upstream_conns(<<"web">>, [{<<"127.0.0.1:8080">>, 3}]),
    pertisk_eproxy_metrics:set_upstream_healthy(<<"web">>, [{<<"127.0.0.1:8080">>, true}]),
    ok.
