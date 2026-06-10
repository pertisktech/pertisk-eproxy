-module(pertisk_eproxy_admin_handler_tests).

-include_lib("eunit/include/eunit.hrl").

ensure_env() ->
    pertisk_eproxy_test_helpers:ensure_config().

h3_light_health_json_test() ->
    Json = pertisk_eproxy_admin_handler:h3_light_health_json(),
    ?assertEqual(<<"{\"status\":\"ok\"}">>, Json).

h3_light_health_json_decodes_test() ->
    Json = pertisk_eproxy_admin_handler:h3_light_health_json(),
    {ok, Map} = thoas:decode(Json),
    ?assertEqual(#{<<"status">> => <<"ok">>}, Map).

build_health_json_returns_map_test() ->
    ensure_env(),
    Json = pertisk_eproxy_admin_handler:build_health_json(),
    {ok, Map} = thoas:decode(Json),
    ?assert(maps:is_key(<<"backends">>, Map)),
    ?assert(maps:is_key(<<"acme">>, Map)),
    ?assert(maps:is_key(<<"tls_sites">>, Map)).

build_health_json_backends_is_list_test() ->
    ensure_env(),
    {ok, Map} = thoas:decode(pertisk_eproxy_admin_handler:build_health_json()),
    ?assert(is_list(maps:get(<<"backends">>, Map, []))).

build_health_json_acme_has_lego_fields_test() ->
    ensure_env(),
    {ok, Map} = thoas:decode(pertisk_eproxy_admin_handler:build_health_json()),
    Acme = maps:get(<<"acme">>, Map),
    ?assert(maps:is_key(<<"lego_installed">>, Acme)),
    ?assert(maps:is_key(<<"lego_required">>, Acme)).

build_health_json_tls_sites_includes_host_test() ->
    ensure_env(),
    Host = <<"health-test.example">>,
    pertisk_eproxy_test_helpers:sync_router(
        [#{host => Host, backend => <<"b">>, routes => []}],
        []
    ),
    try
        {ok, Map} = thoas:decode(pertisk_eproxy_admin_handler:build_health_json()),
        TlsSites = maps:get(<<"tls_sites">>, Map),
        ?assert(
            lists:any(
                fun(Row) -> maps:get(<<"host">>, Row, undefined) =:= Host end,
                TlsSites
            )
        )
    after
        pertisk_eproxy_test_helpers:sync_router([], [])
    end.

build_health_json_with_backend_test() ->
    ensure_env(),
    Name = <<"hb_test_", (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    {ok, Pid} = pertisk_eproxy_test_helpers:start_backend(Name, [#{addr => <<"127.0.0.1:9">>}]),
    try
        pertisk_eproxy_test_helpers:sync_router(
            [],
            [#{name => Name, upstreams => [#{addr => <<"127.0.0.1:9">>}]}]
        ),
        {ok, Map} = thoas:decode(pertisk_eproxy_admin_handler:build_health_json()),
        Backends = maps:get(<<"backends">>, Map),
        ?assert(
            lists:any(
                fun(Row) ->
                    maps:get(<<"name">>, Row, undefined) =:= Name
                end,
                Backends
            )
        ),
        [Row | _] = [R || R <- Backends, maps:get(<<"name">>, R, undefined) =:= Name],
        ?assert(maps:is_key(<<"total">>, Row)),
        ?assert(maps:is_key(<<"healthy">>, Row))
    after
        catch gen_server:stop(Pid, normal, 5000),
        pertisk_eproxy_test_helpers:sync_router([], [])
    end.

