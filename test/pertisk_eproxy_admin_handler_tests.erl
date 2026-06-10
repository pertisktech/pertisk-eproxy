-module(pertisk_eproxy_admin_handler_tests).

-include_lib("eunit/include/eunit.hrl").

ensure_env() ->
    pertisk_eproxy_test_helpers:ensure_config(),
    case whereis(pertisk_eproxy_access_log) of
        undefined -> {ok, _} = pertisk_eproxy_access_log:start_link();
        _ -> ok
    end.

ensure_ingress_status_env() ->
    ensure_env(),
    ok = pertisk_ingress_status:init(),
    case whereis(pertisk_ingress_tls) of
        undefined -> {ok, _} = pertisk_ingress_tls:start_link();
        _ -> ok
    end.

dispatch(Method, Path) ->
    dispatch(Method, Path, <<>>, <<>>).

dispatch(Method, Path, Body) ->
    dispatch(Method, Path, <<>>, Body).

dispatch(Method, Path, Qs, Body) ->
    pertisk_eproxy_h3_local_admin:try_dispatch(
        Method, <<"localhost">>, Path, Qs, [], Body, <<"127.0.0.1">>
    ).

with_tmp_db(Fun) ->
    DbPath = pertisk_eproxy_test_helpers:tmp_db(),
    file:delete(DbPath),
    OldDb = application:get_env(pertisk_eproxy, db_file),
    application:set_env(pertisk_eproxy, db_file, DbPath),
    ensure_env(),
    try
        ?assertMatch({ok, _}, pertisk_eproxy_db:init(DbPath)),
        Fun(DbPath)
    after
        case OldDb of
            {ok, V} -> application:set_env(pertisk_eproxy, db_file, V);
            undefined -> application:unset_env(pertisk_eproxy, db_file)
        end,
        file:delete(DbPath)
    end.

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

api_version_get_test() ->
    ensure_env(),
    ?assertMatch({ok, 200, _, _}, dispatch(<<"GET">>, <<"/api/version">>)).

api_management_get_test() ->
    ensure_env(),
    {ok, 200, _, Body} = dispatch(<<"GET">>, <<"/api/management">>),
    ?assert(byte_size(Body) > 0).

api_stats_get_test() ->
    ensure_env(),
    ?assertMatch({ok, 200, _, _}, dispatch(<<"GET">>, <<"/api/stats">>)).

api_logs_get_test() ->
    ensure_env(),
    ?assertMatch({ok, 200, _, _}, dispatch(<<"GET">>, <<"/api/logs">>)).

api_config_get_test() ->
    ensure_env(),
    ?assertMatch({ok, 200, _, _}, dispatch(<<"GET">>, <<"/api/config">>)).

api_sites_get_test() ->
    ensure_env(),
    ?assertMatch({ok, 200, _, _}, dispatch(<<"GET">>, <<"/api/sites">>)).

api_backends_get_test() ->
    ensure_env(),
    ?assertMatch({ok, 200, _, _}, dispatch(<<"GET">>, <<"/api/backends">>)).

api_reload_post_test() ->
    ensure_env(),
    ?assertMatch({ok, _, _, _}, dispatch(<<"POST">>, <<"/api/reload">>)).

api_proto_get_test() ->
    ensure_env(),
    ?assertMatch({ok, 200, _, _}, dispatch(<<"GET">>, <<"/api/proto">>)).

api_auth_config_get_test() ->
    ensure_env(),
    ?assertMatch({ok, 200, _, _}, dispatch(<<"GET">>, <<"/api/auth/config">>)).

api_auth_check_get_test() ->
    ensure_env(),
    ?assertMatch({ok, 200, _, _}, dispatch(<<"GET">>, <<"/api/auth/check">>)).

api_auth_logout_post_test() ->
    ensure_env(),
    ?assertMatch({ok, 200, _, _}, dispatch(<<"POST">>, <<"/api/auth/logout">>)).

api_admin_change_password_post_test() ->
    ensure_env(),
    ?assertMatch({ok, 501, _, _}, dispatch(<<"POST">>, <<"/api/admin/change-password">>)).

api_admin_api_token_get_test() ->
    ensure_env(),
    ?assertMatch({ok, 200, _, _}, dispatch(<<"GET">>, <<"/api/admin/api-token">>)).

api_admin_api_token_post_test() ->
    ensure_env(),
    ?assertMatch({ok, 501, _, _}, dispatch(<<"POST">>, <<"/api/admin/api-token">>)).

api_backup_export_get_test() ->
    ensure_env(),
    ?assertMatch({ok, 200, _, _}, dispatch(<<"GET">>, <<"/api/backup/export">>)).

api_certificates_get_test() ->
    with_tmp_db(fun(_Db) ->
        ?assertMatch({ok, 200, _, _}, dispatch(<<"GET">>, <<"/api/certificates">>))
    end).

api_dns_providers_get_test() ->
    with_tmp_db(fun(_Db) ->
        ?assertMatch({ok, 200, _, _}, dispatch(<<"GET">>, <<"/api/dns-providers">>))
    end).

api_dns_provider_validate_post_test() ->
    with_tmp_db(fun(_Db) ->
        Body = thoas:encode(#{
            <<"provider_type">> => <<"cloudflare">>,
            <<"credentials">> => #{<<"api_token">> => <<"tok">>}
        }),
        ?assertMatch({ok, 200, _, _}, dispatch(<<"POST">>, <<"/api/dns-providers/validate">>, Body))
    end).

api_tls_listener_post_missing_pem_test() ->
    ensure_env(),
    Body = thoas:encode(#{<<"cert_pem">> => <<>>, <<"key_pem">> => <<>>}),
    ?assertMatch({ok, 400, _, _}, dispatch(<<"POST">>, <<"/api/tls/listener">>, Body)).

api_ingress_status_get_test() ->
    ensure_ingress_status_env(),
    ?assertMatch({ok, 200, _, _}, dispatch(<<"GET">>, <<"/api/ingress/status">>)).

api_ingress_watchers_get_test() ->
    ensure_ingress_status_env(),
    ?assertMatch({ok, 200, _, _}, dispatch(<<"GET">>, <<"/api/ingress/watchers">>)).

api_ingress_errors_get_test() ->
    ensure_ingress_status_env(),
    ?assertMatch({ok, 200, _, _}, dispatch(<<"GET">>, <<"/api/ingress/errors">>)).

api_ingress_resources_get_test() ->
    ensure_env(),
    ?assertMatch({ok, 200, _, _}, dispatch(<<"GET">>, <<"/api/ingress/resources">>)).

api_sites_post_test() ->
    ensure_env(),
    Body = thoas:encode(#{
        <<"host">> => <<"new-site.example">>,
        <<"backend">> => <<"web">>,
        <<"routes">> => []
    }),
    try
        ?assertMatch({ok, 201, _, _}, dispatch(<<"POST">>, <<"/api/sites">>, Body))
    after
        _ = dispatch(<<"DELETE">>, <<"/api/sites/new-site.example">>)
    end.

api_backends_post_test() ->
    ensure_env(),
    Name = <<"bh_", (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    Body = thoas:encode(#{
        <<"name">> => Name,
        <<"algorithm">> => <<"round_robin">>,
        <<"upstreams">> => [#{<<"addr">> => <<"127.0.0.1:9">>}]
    }),
    try
        ?assertMatch({ok, 201, _, _}, dispatch(<<"POST">>, <<"/api/backends">>, Body))
    after
        _ = dispatch(<<"DELETE">>, <<"/api/backends/", Name/binary>>)
    end.

api_certificates_post_test() ->
    with_tmp_db(fun(_Db) ->
        Body = thoas:encode(#{<<"name">> => <<"test-cert">>}),
        ?assertMatch({ok, 201, _, _}, dispatch(<<"POST">>, <<"/api/certificates">>, Body))
    end).

api_dns_providers_post_test() ->
    with_tmp_db(fun(_Db) ->
        Body = thoas:encode(#{
            <<"name">> => <<"cf-test">>,
            <<"provider_type">> => <<"cloudflare">>,
            <<"credentials">> => #{<<"api_token">> => <<"secret">>}
        }),
        ?assertMatch({ok, 201, _, _}, dispatch(<<"POST">>, <<"/api/dns-providers">>, Body))
    end).

api_backup_restore_invalid_json_test() ->
    ensure_env(),
    Body = thoas:encode(#{<<"data">> => <<"not-json">>}),
    ?assertMatch({ok, 400, _, _}, dispatch(<<"POST">>, <<"/api/backup/restore">>, Body)).

api_helm_history_not_ingress_test() ->
    ensure_env(),
    ?assertMatch({ok, 404, _, _}, dispatch(<<"GET">>, <<"/api/helm/history">>)).

api_kubernetes_not_available_test() ->
    ensure_env(),
    ?assertMatch({ok, 404, _, _}, dispatch(<<"GET">>, <<"/api/kubernetes/namespaces">>)).

api_config_put_test() ->
    ensure_env(),
    {ok, 200, _, Body} = dispatch(<<"GET">>, <<"/api/config">>),
    ?assertMatch({ok, 200, _, _}, dispatch(<<"PUT">>, <<"/api/config">>, Body)).

api_site_get_test() ->
    ensure_env(),
    Host = <<"get-site.example">>,
    Add = thoas:encode(#{
        <<"host">> => Host,
        <<"backend">> => <<"web">>,
        <<"routes">> => []
    }),
    try
        _ = dispatch(<<"POST">>, <<"/api/sites">>, Add),
        ?assertMatch({ok, 200, _, _}, dispatch(<<"GET">>, <<"/api/sites/get-site.example">>))
    after
        _ = dispatch(<<"DELETE">>, <<"/api/sites/get-site.example">>)
    end.

api_certificate_delete_invalid_id_test() ->
    with_tmp_db(fun(_Db) ->
        ?assertMatch({ok, 400, _, _}, dispatch(<<"DELETE">>, <<"/api/certificates/not-a-number">>))
    end).

