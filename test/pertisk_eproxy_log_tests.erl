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

http_warn_log_test() ->
    application:ensure_all_started(lager),
    ?assertEqual(ok, pertisk_eproxy_log:http(<<"warn">>, <<"h2">>, <<"host">>, <<"GET">>, <<"/">>, 404, 2)).

http_warning_log_test() ->
    application:ensure_all_started(lager),
    ?assertEqual(ok, pertisk_eproxy_log:http(<<"warning">>, <<"h1">>, <<"host">>, <<"POST">>, <<"/api">>, 429, 3)).

http_error_log_test() ->
    application:ensure_all_started(lager),
    ?assertEqual(ok, pertisk_eproxy_log:http(<<"error">>, <<"h2">>, <<"host">>, <<"GET">>, <<"/">>, 500, 4)).

warning_format_error_test() ->
    application:ensure_all_started(lager),
    ?assertEqual(ok, pertisk_eproxy_log:warning("bad ~q", [not_a_list])).

error_format_error_test() ->
    application:ensure_all_started(lager),
    ?assertEqual(ok, pertisk_eproxy_log:error("bad ~q", [not_a_list])).
