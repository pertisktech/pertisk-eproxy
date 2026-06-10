-module(pertisk_eproxy_admin_handler_tests).

-include_lib("eunit/include/eunit.hrl").

h3_light_health_json_test() ->
    Json = pertisk_eproxy_admin_handler:h3_light_health_json(),
    {ok, Map} = thoas:decode(Json),
    ?assertEqual(<<"ok">>, maps:get(<<"status">>, Map)).

build_health_json_returns_map_test() ->
    application:ensure_all_started(lager),
    case whereis(pertisk_eproxy_config) of
        undefined -> {ok, _} = pertisk_eproxy_config:start_link();
        _ -> ok
    end,
    Json = pertisk_eproxy_admin_handler:build_health_json(),
    {ok, Map} = thoas:decode(Json),
    ?assert(is_map_key(backends, Map)),
    ?assert(is_map_key(acme, Map)),
    ?assert(is_map_key(tls_sites, Map)).

is_map_key(K, Map) when is_atom(K) ->
    maps:is_key(atom_to_binary(K, utf8), Map).
