-module(pertisk_eproxy_access_log_tests).

-include_lib("eunit/include/eunit.hrl").

is_health_path_api_health_test() ->
    ?assert(pertisk_eproxy_access_log:is_health_path(<<"/api/health">>)).

is_health_path_variants_test() ->
    ?assert(pertisk_eproxy_access_log:is_health_path(<<"/health">>)),
    ?assert(pertisk_eproxy_access_log:is_health_path(<<"/healthz">>)),
    ?assert(pertisk_eproxy_access_log:is_health_path(<<"/readyz">>)).

is_health_path_other_test() ->
    ?assertNot(pertisk_eproxy_access_log:is_health_path(<<"/api/config">>)).

with_server(Fun) ->
    case whereis(pertisk_eproxy_access_log) of
        undefined ->
            {ok, Pid} = pertisk_eproxy_access_log:start_link(),
            try Fun() after catch gen_server:stop(Pid, normal, 5000) end;
        _ ->
            Fun()
    end.

log_proxy_and_list_test() ->
    pertisk_eproxy_test_helpers:ensure_config(),
    with_server(fun() ->
        pertisk_eproxy_access_log:refresh_hot_path_flags(),
        ?assertEqual(ok,
            pertisk_eproxy_access_log:log_proxy(
                <<"host.example">>, <<"GET">>, <<"/page">>, 200, 5, 'HTTP/1.1'
            )),
        Entries = pertisk_eproxy_access_log:list(undefined, undefined),
        ?assert(length(Entries) >= 1),
        ?assert(is_integer(pertisk_eproxy_access_log:count()))
    end).

log_proxy_skips_health_200_test() ->
    pertisk_eproxy_test_helpers:ensure_config(),
    with_server(fun() ->
        Before = pertisk_eproxy_access_log:count(),
        ?assertEqual(ok,
            pertisk_eproxy_access_log:log_proxy(
                <<"host">>, <<"GET">>, <<"/api/health">>, 200, 1, 'HTTP/1.1'
            )),
        ?assertEqual(Before, pertisk_eproxy_access_log:count())
    end).

log_proxy_logs_health_500_test() ->
    pertisk_eproxy_test_helpers:ensure_config(),
    with_server(fun() ->
        Before = pertisk_eproxy_access_log:count(),
        ?assertEqual(ok,
            pertisk_eproxy_access_log:log_proxy(
                <<"host">>, <<"GET">>, <<"/api/health">>, 500, 1, 'HTTP/1.1'
            )),
        ?assert(pertisk_eproxy_access_log:count() > Before)
    end).

log_system_test() ->
    with_server(fun() ->
        ?assertEqual(ok, pertisk_eproxy_access_log:log_system(<<"error">>, <<"crash">>, <<"boom">>)),
        Entries = pertisk_eproxy_access_log:list(<<"error">>, undefined),
        ?assert(length(Entries) >= 1)
    end).

gen_server_callbacks_test() ->
    {ok, St} = pertisk_eproxy_access_log:init([]),
    ?assertMatch({reply, _, _},
        pertisk_eproxy_access_log:handle_call({list, undefined, undefined, undefined}, self(), St)),
    ?assertMatch({reply, 0, _}, pertisk_eproxy_access_log:handle_call(count, self(), St)),
    ?assertMatch({noreply, _},
        pertisk_eproxy_access_log:handle_cast(
            {log, <<"h">>, <<"GET">>, <<"/">>, 200, 1, http, <<>>, <<"h">>}, St
        )),
    ?assertEqual(ok, pertisk_eproxy_access_log:terminate(normal, St)),
    ?assertMatch({ok, _}, pertisk_eproxy_access_log:code_change(1, St, extra)).
