-module(pertisk_eproxy_log_tests).

-include_lib("eunit/include/eunit.hrl").

info_emits_ok_test() ->
    application:ensure_all_started(lager),
    ?assertEqual(ok, pertisk_eproxy_log:info("test ~s", ["message"])).

warning_emits_ok_test() ->
    application:ensure_all_started(lager),
    ?assertEqual(ok, pertisk_eproxy_log:warning("warn ~s", ["message"])).

error_emits_ok_test() ->
    application:ensure_all_started(lager),
    ?assertEqual(ok, pertisk_eproxy_log:error("err ~s", ["message"])).

http_log_test() ->
    application:ensure_all_started(lager),
    ?assertEqual(ok, pertisk_eproxy_log:http(<<"info">>, <<"h2">>, <<"host">>, <<"GET">>, <<"/">>, 200, 1)).
