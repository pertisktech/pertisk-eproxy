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
        undefined -> {ok, _} = pertisk_eproxy_access_log:start_link();
        _ -> ok
    end,
    Fun().

log_proxy_and_list_test() ->
    pertisk_eproxy_test_helpers:ensure_config(),
    Base = pertisk_eproxy_config:get_config(),
    ok = pertisk_eproxy_test_helpers:put_config_retry(Base#{proxy_access_log => true}),
    try
        with_server(fun() ->
            pertisk_eproxy_access_log:refresh_hot_path_flags(),
            ?assertEqual(ok,
                pertisk_eproxy_access_log:log_proxy(
                    <<"host.example">>, <<"GET">>, <<"/page">>, 200, 5, 'HTTP/1.1'
                )),
            Entries = pertisk_eproxy_access_log:list(undefined, undefined),
            ?assert(length(Entries) >= 1),
            ?assert(is_integer(pertisk_eproxy_access_log:count()))
        end)
    after
        ok = pertisk_eproxy_test_helpers:put_config_retry(Base)
    end.

log_proxy_skips_health_200_test() ->
    pertisk_eproxy_test_helpers:ensure_config(),
    Base = pertisk_eproxy_config:get_config(),
    Config = maps:merge(Base, #{health_access_log => false, health_access_log_sample => 0}),
    ok = pertisk_eproxy_test_helpers:put_config_retry(Config),
    with_server(fun() ->
        pertisk_eproxy_access_log:refresh_hot_path_flags(),
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

log_proxy_with_site_and_host_filter_test() ->
    pertisk_eproxy_test_helpers:ensure_config(),
    Base = pertisk_eproxy_config:get_config(),
    ok = pertisk_eproxy_test_helpers:put_config_retry(Base#{proxy_access_log => true}),
    try
        with_server(fun() ->
            pertisk_eproxy_access_log:refresh_hot_path_flags(),
            ?assertEqual(ok,
                pertisk_eproxy_access_log:log_proxy(
                    <<"filter.example">>, <<"GET">>, <<"/page">>, 200, 3, 'HTTP/1.1',
                    <<"10.0.0.1">>, <<"filter.example">>
                )),
            ByHost = pertisk_eproxy_access_log:list(undefined, <<"filter.example">>, undefined),
            ?assert(length(ByHost) >= 1),
            BySite = pertisk_eproxy_access_log:list(undefined, undefined, <<"filter.example">>),
            ?assert(length(BySite) >= 1)
        end)
    after
        ok = pertisk_eproxy_test_helpers:put_config_retry(Base)
    end.

log_proxy_skips_readyz_200_test() ->
    pertisk_eproxy_test_helpers:ensure_config(),
    Base = pertisk_eproxy_config:get_config(),
    Config = maps:merge(Base, #{health_access_log => false, health_access_log_sample => 0}),
    ok = pertisk_eproxy_test_helpers:put_config_retry(Config),
    with_server(fun() ->
        pertisk_eproxy_access_log:refresh_hot_path_flags(),
        Before = pertisk_eproxy_access_log:count(),
        ?assertEqual(ok,
            pertisk_eproxy_access_log:log_proxy(
                <<"host">>, <<"GET">>, <<"/readyz">>, 200, 1, 'HTTP/1.1'
            )),
        ?assertEqual(Before, pertisk_eproxy_access_log:count())
    end).

log_proxy_type_filter_test() ->
    with_server(fun() ->
        ?assertEqual(ok, pertisk_eproxy_access_log:log_system(<<"warn">>, <<"boot">>, <<"started">>)),
        Entries = pertisk_eproxy_access_log:list(<<"warn">>, undefined),
        ?assert(length(Entries) >= 1)
    end).

handle_info_unknown_ignored_test() ->
    {ok, St} = pertisk_eproxy_access_log:init([]),
    ?assertMatch({noreply, _}, pertisk_eproxy_access_log:handle_info(unknown, St)).

handle_call_unknown_test() ->
    {ok, St} = pertisk_eproxy_access_log:init([]),
    ?assertMatch({reply, {error, unknown}, _},
        pertisk_eproxy_access_log:handle_call(unknown, self(), St)).

log_proxy_skips_2xx_when_proxy_access_log_disabled_test() ->
    pertisk_eproxy_test_helpers:ensure_config(),
    Old = os:getenv("PERTISK_PROXY_ACCESS_LOG"),
    os:putenv("PERTISK_PROXY_ACCESS_LOG", "false"),
    with_server(fun() ->
        pertisk_eproxy_access_log:refresh_hot_path_flags(),
        Before = pertisk_eproxy_access_log:count(),
        ?assertEqual(ok,
            pertisk_eproxy_access_log:log_proxy(
                <<"host">>, <<"GET">>, <<"/ok">>, 200, 1, 'HTTP/1.1'
            )),
        ?assertEqual(Before, pertisk_eproxy_access_log:count())
    end),
    case Old of
        false -> os:unsetenv("PERTISK_PROXY_ACCESS_LOG");
        V -> os:putenv("PERTISK_PROXY_ACCESS_LOG", V)
    end.

log_proxy_logs_4xx_when_proxy_access_log_disabled_test() ->
    pertisk_eproxy_test_helpers:ensure_config(),
    Old = os:getenv("PERTISK_PROXY_ACCESS_LOG"),
    os:putenv("PERTISK_PROXY_ACCESS_LOG", "false"),
    with_server(fun() ->
        pertisk_eproxy_access_log:refresh_hot_path_flags(),
        Before = pertisk_eproxy_access_log:count(),
        ?assertEqual(ok,
            pertisk_eproxy_access_log:log_proxy(
                <<"host">>, <<"GET">>, <<"/missing">>, 404, 2, 'HTTP/2'
            )),
        ?assert(pertisk_eproxy_access_log:count() > Before)
    end),
    case Old of
        false -> os:unsetenv("PERTISK_PROXY_ACCESS_LOG");
        V -> os:putenv("PERTISK_PROXY_ACCESS_LOG", V)
    end.

log_proxy_logs_5xx_test() ->
    with_server(fun() ->
        pertisk_eproxy_access_log:refresh_hot_path_flags(),
        ?assertEqual(ok,
            pertisk_eproxy_access_log:log_proxy(
                <<"host">>, <<"POST">>, <<"/err">>, 503, 3, 'HTTP/3'
            )),
        Entries = pertisk_eproxy_access_log:list(<<"error">>, undefined),
        ?assert(length(Entries) >= 1)
    end).

log_proxy_seven_arg_upstream_test() ->
    pertisk_eproxy_test_helpers:ensure_config(),
    with_server(fun() ->
        pertisk_eproxy_access_log:refresh_hot_path_flags(),
        ?assertEqual(ok,
            pertisk_eproxy_access_log:log_proxy(
                <<"host">>, <<"GET">>, <<"/api">>, 404, 1, 'HTTP/1.1', <<"127.0.0.1:8080">>
            )),
        Entries = pertisk_eproxy_access_log:list(undefined, undefined),
        ?assert(length(Entries) >= 1),
        Upstreams = [maps:get(<<"upstream">>, E) || E <- Entries, maps:is_key(<<"upstream">>, E)],
        ?assert(lists:member(<<"127.0.0.1:8080">>, Upstreams))
    end).

list_type_proxy_and_system_filters_test() ->
    pertisk_eproxy_test_helpers:ensure_config(),
    Base = pertisk_eproxy_config:get_config(),
    ok = pertisk_eproxy_test_helpers:put_config_retry(Base#{proxy_access_log => true}),
    try
        with_server(fun() ->
            pertisk_eproxy_access_log:refresh_hot_path_flags(),
            ?assertEqual(ok, pertisk_eproxy_access_log:log_system(<<"info">>, <<"system">>, <<"boot">>)),
            ?assertEqual(ok,
                pertisk_eproxy_access_log:log_proxy(
                    <<"h">>, <<"GET">>, <<"/">>, 200, 1, 'HTTP/1.0'
                )),
            ?assert(length(pertisk_eproxy_access_log:list(<<"proxy">>, undefined)) >= 1),
            ?assert(length(pertisk_eproxy_access_log:list(<<"system">>, undefined)) >= 1),
            ?assert(length(pertisk_eproxy_access_log:list(<<"all">>, undefined)) >= 2)
        end)
    after
        ok = pertisk_eproxy_test_helpers:put_config_retry(Base)
    end.

health_access_log_enabled_logs_200_test() ->
    pertisk_eproxy_test_helpers:ensure_config(),
    Base = pertisk_eproxy_config:get_config(),
    Config = Base#{proxy_access_log => false, health_access_log => true, health_access_log_sample => 0},
    ok = pertisk_eproxy_test_helpers:put_config_retry(Config),
    try
        with_server(fun() ->
            pertisk_eproxy_access_log:refresh_hot_path_flags(),
            Before = pertisk_eproxy_access_log:count(),
            ?assertEqual(ok,
                pertisk_eproxy_access_log:log_proxy(
                    <<"host">>, <<"GET">>, <<"/healthz">>, 200, 1, 'HTTP/1.1'
                )),
            ?assert(pertisk_eproxy_access_log:count() > Before)
        end)
    after
        ok = pertisk_eproxy_test_helpers:put_config_retry(Base)
    end.

ring_buffer_trim_test() ->
    with_server(fun() ->
        pertisk_eproxy_access_log:refresh_hot_path_flags(),
        lists:foreach(
            fun(N) ->
                ok = pertisk_eproxy_access_log:log_system(
                    <<"info">>, <<"t">>, integer_to_binary(N)
                )
            end,
            lists:seq(1, 1005)
        ),
        ?assertEqual(1000, pertisk_eproxy_access_log:count())
    end).

kube_omni_kube_api_401_downgraded_to_info_test() ->
    pertisk_eproxy_test_helpers:ensure_config(),
    Base = pertisk_eproxy_config:get_config(),
    ok = pertisk_eproxy_test_helpers:put_config_retry(Base#{proxy_access_log => true}),
    try
        with_server(fun() ->
            pertisk_eproxy_access_log:refresh_hot_path_flags(),
            ?assertEqual(ok,
                pertisk_eproxy_access_log:log_proxy(
                    <<"kube.omni.thaidevops.co">>,
                    <<"GET">>,
                    <<"/apis/apiextensions.k8s.io/v1/customresourcedefinitions">>,
                    401,
                    1,
                    'HTTP/1.1',
                    <<"http://127.0.0.1:8100">>,
                    <<"kube.omni.thaidevops.co">>
                )),
            Entries = pertisk_eproxy_access_log:list(undefined, <<"kube.omni.thaidevops.co">>, undefined),
            [Latest | _] = lists:reverse(Entries),
            ?assertEqual(<<"info">>, maps:get(<<"level">>, Latest))
        end)
    after
        ok = pertisk_eproxy_test_helpers:put_config_retry(Base)
    end.

non_kube_401_remains_warn_test() ->
    pertisk_eproxy_test_helpers:ensure_config(),
    Base = pertisk_eproxy_config:get_config(),
    ok = pertisk_eproxy_test_helpers:put_config_retry(Base#{proxy_access_log => true}),
    try
        with_server(fun() ->
            pertisk_eproxy_access_log:refresh_hot_path_flags(),
            ?assertEqual(ok,
                pertisk_eproxy_access_log:log_proxy(
                    <<"other.example">>,
                    <<"GET">>,
                    <<"/private">>,
                    401,
                    1,
                    'HTTP/2',
                    <<"http://127.0.0.1:9999">>,
                    <<"other.example">>
                )),
            Entries = pertisk_eproxy_access_log:list(undefined, <<"other.example">>, undefined),
            [Latest | _] = lists:reverse(Entries),
            ?assertEqual(<<"warn">>, maps:get(<<"level">>, Latest))
        end)
    after
        ok = pertisk_eproxy_test_helpers:put_config_retry(Base)
    end.
