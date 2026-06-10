-module(pertisk_eproxy_health_cache_tests).

-include_lib("eunit/include/eunit.hrl").

ensure_config() ->
    application:ensure_all_started(lager),
    case whereis(pertisk_eproxy_config) of
        undefined -> {ok, _} = pertisk_eproxy_config:start_link();
        _ -> ok
    end.

start_get_and_invalidate_test() ->
    ensure_config(),
    case whereis(pertisk_eproxy_health_cache) of
        undefined -> {ok, _} = pertisk_eproxy_health_cache:start_link();
        _ -> ok
    end,
    ?assertMatch({ok, Body} when is_binary(Body), pertisk_eproxy_health_cache:get()),
    ok = pertisk_eproxy_health_cache:invalidate(),
    ?assertMatch({ok, _}, pertisk_eproxy_health_cache:get()).
