-module(pertisk_eproxy_admin_management_snapshot_tests).

-include_lib("eunit/include/eunit.hrl").

ensure_config() ->
    application:ensure_all_started(lager),
    case whereis(pertisk_eproxy_config) of
        undefined -> {ok, _} = pertisk_eproxy_config:start_link();
        _ -> ok
    end.

app_version_is_binary_test() ->
    V = pertisk_eproxy_admin_management_snapshot:app_version(),
    ?assert(is_binary(V)),
    ?assert(byte_size(V) > 0).

init_cpu_sample_test() ->
    ?assertEqual(ok, pertisk_eproxy_admin_management_snapshot:init_cpu_sample()).

snapshot_has_core_keys_test() ->
    ensure_config(),
    S = pertisk_eproxy_admin_management_snapshot:snapshot(),
    ?assert(is_map_key(<<"version">>, S)),
    ?assert(is_map_key(<<"mode">>, S)),
    ?assert(is_map_key(<<"listeners">>, S)).
