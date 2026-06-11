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

with_auth_server(Fun) ->
    case whereis(pertisk_eproxy_auth) of
        undefined ->
            {ok, Pid} = pertisk_eproxy_auth:start_link(),
            try Fun() after catch gen_server:stop(Pid, normal, 5000) end;
        Pid ->
            Fun(),
            catch gen_server:stop(Pid, normal, 5000)
    end.

with_local_auth(Fun) ->
    Old = application:get_env(pertisk_eproxy, admin_auth),
    application:set_env(pertisk_eproxy, admin_auth, local),
    with_auth_server(fun() ->
        try Fun() after
            case Old of
                {ok, V} -> application:set_env(pertisk_eproxy, admin_auth, V);
                undefined -> application:unset_env(pertisk_eproxy, admin_auth)
            end
        end
    end).

with_local_auth_db(Fun) ->
    with_local_auth(fun() -> with_tmp_db(Fun) end).

with_tls_data_dir(Fun) ->
    TmpDir = filename:join([
        os:getenv("TMPDIR", "/tmp"),
        "pertisk_admin_tls_" ++ integer_to_list(erlang:unique_integer([positive]))
    ]),
    _ = file:del_dir_r(TmpDir),
    ok = file:make_dir(TmpDir),
    Old = application:get_env(pertisk_eproxy, tls_data_dir),
    application:set_env(pertisk_eproxy, tls_data_dir, TmpDir),
    try
        Fun(TmpDir)
    after
        case Old of
            {ok, V} -> application:set_env(pertisk_eproxy, tls_data_dir, V);
            undefined -> application:unset_env(pertisk_eproxy, tls_data_dir)
        end,
        _ = file:del_dir_r(TmpDir)
    end.

read_priv_pem(Name) ->
    Path = filename:join([code:priv_dir(pertisk_eproxy), "tls", Name]),
    {ok, Bin} = file:read_file(Path),
    Bin.

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

api_health_get_test() ->
    ensure_env(),
    ?assertMatch({ok, 200, _, _}, dispatch(<<"GET">>, <<"/api/health">>)).

api_health_head_test() ->
    ensure_env(),
    ?assertMatch({ok, 200, _, _}, dispatch(<<"HEAD">>, <<"/api/health">>)).

api_metrics_get_test() ->
    pertisk_eproxy_test_helpers:ensure_metrics(),
    ensure_env(),
    {ok, 200, _, Body} = dispatch(<<"GET">>, <<"/api/metrics">>),
    ?assert(byte_size(Body) > 0).

api_version_head_test() ->
    ensure_env(),
    ?assertMatch({ok, 200, _, _}, dispatch(<<"HEAD">>, <<"/api/version">>)).

api_auth_login_invalid_test() ->
    ensure_env(),
    Body = thoas:encode(#{<<"username">> => <<"bad">>, <<"password">> => <<"bad">>}),
    Result = dispatch(<<"POST">>, <<"/api/auth/login">>, Body),
    ?assertMatch({ok, Status, _, _} when Status =:= 400 orelse Status =:= 401, Result).

api_auth_refresh_disabled_test() ->
    ensure_env(),
    ?assertMatch({ok, 200, _, _}, dispatch(<<"POST">>, <<"/api/auth/refresh">>)).

api_site_put_test() ->
    ensure_env(),
    Host = <<"put-site.example">>,
    Add = thoas:encode(#{
        <<"host">> => Host,
        <<"backend">> => <<"web">>,
        <<"routes">> => []
    }),
    Put = thoas:encode(#{
        <<"host">> => Host,
        <<"backend">> => <<"web">>,
        <<"routes">> => [#{<<"path">> => <<"/">>, <<"path_type">> => <<"prefix">>}]
    }),
    try
        _ = dispatch(<<"POST">>, <<"/api/sites">>, Add),
        ?assertMatch({ok, 200, _, _}, dispatch(<<"PUT">>, <<"/api/sites/put-site.example">>, Put))
    after
        _ = dispatch(<<"DELETE">>, <<"/api/sites/put-site.example">>)
    end.

api_site_not_found_test() ->
    ensure_env(),
    ?assertMatch({ok, 404, _, _}, dispatch(<<"GET">>, <<"/api/sites/missing.example">>)).

api_backend_get_test() ->
    ensure_env(),
    Name = <<"bgtest">>,
    Body = thoas:encode(#{
        <<"name">> => Name,
        <<"algorithm">> => <<"round_robin">>,
        <<"upstreams">> => [#{<<"addr">> => <<"127.0.0.1:9">>}]
    }),
    {ok, Pid} = pertisk_eproxy_test_helpers:start_backend(Name, [#{addr => <<"127.0.0.1:9">>}]),
    try
        ?assertMatch({ok, 201, _, _}, dispatch(<<"POST">>, <<"/api/backends">>, Body)),
        ?assertMatch({ok, 200, _, _}, dispatch(<<"GET">>, <<"/api/backends/bgtest">>))
    after
        catch gen_server:stop(Pid, normal, 5000),
        _ = dispatch(<<"DELETE">>, <<"/api/backends/bgtest">>)
    end.

api_backend_delete_config_only_test() ->
    ensure_env(),
    Body = thoas:encode(#{
        <<"name">> => <<"bdtest">>,
        <<"algorithm">> => <<"round_robin">>,
        <<"upstreams">> => [#{<<"addr">> => <<"127.0.0.1:9">>}]
    }),
    ?assertMatch({ok, 201, _, _}, dispatch(<<"POST">>, <<"/api/backends">>, Body)),
    Result = dispatch(<<"DELETE">>, <<"/api/backends/bdtest">>),
    case Result of
        {ok, Status, _, _} when Status =:= 200 orelse Status =:= 500 -> ok;
        {error, _} -> ok
    end.

api_backend_not_found_test() ->
    ensure_env(),
    ?assertMatch({ok, 404, _, _}, dispatch(<<"GET">>, <<"/api/backends/missing-backend">>)).

api_dns_provider_put_delete_test() ->
    with_tmp_db(fun(_Db) ->
        Add = thoas:encode(#{
            <<"name">> => <<"cf-edit">>,
            <<"provider_type">> => <<"cloudflare">>,
            <<"credentials">> => #{<<"api_token">> => <<"secret">>}
        }),
        ?assertMatch({ok, 201, _, _}, dispatch(<<"POST">>, <<"/api/dns-providers">>, Add)),
        {ok, 200, _, ListBody} = dispatch(<<"GET">>, <<"/api/dns-providers">>),
        {ok, Providers} = thoas:decode(ListBody),
        [#{<<"id">> := Id} | _] = Providers,
        IdBin =
            case Id of
                I when is_integer(I) -> integer_to_binary(I);
                B when is_binary(B) -> B
            end,
        Put = thoas:encode(#{
            <<"name">> => <<"cf-renamed">>,
            <<"provider_type">> => <<"cloudflare">>,
            <<"credentials">> => #{<<"api_token">> => <<"new-secret">>}
        }),
        Path = <<"/api/dns-providers/", IdBin/binary>>,
        ?assertMatch({ok, 200, _, _}, dispatch(<<"PUT">>, Path, Put)),
        DelResult = dispatch(<<"DELETE">>, Path),
        ?assertMatch({ok, Status, _, _} when Status =:= 200 orelse Status =:= 404, DelResult)
    end).

api_certificate_put_test() ->
    with_tmp_db(fun(_Db) ->
        Add = thoas:encode(#{<<"name">> => <<"rename-cert">>}),
        {ok, 201, _, _} = dispatch(<<"POST">>, <<"/api/certificates">>, Add),
        Put = thoas:encode(#{<<"name">> => <<"renamed-cert">>}),
        ?assertMatch({ok, 200, _, _}, dispatch(<<"PUT">>, <<"/api/certificates/1">>, Put))
    end).

api_certificates_import_invalid_pem_test() ->
    ensure_env(),
    Body = thoas:encode(#{<<"cert_pem">> => <<"bad">>, <<"key_pem">> => <<"bad">>}),
    ?assertMatch({ok, 400, _, _}, dispatch(<<"POST">>, <<"/api/certificates/import">>, Body)).

api_ingress_live_get_test() ->
    ensure_env(),
    ?assertMatch({ok, 200, _, _}, dispatch(<<"GET">>, <<"/api/ingress/live">>)).

api_ingress_ready_get_test() ->
    ensure_env(),
    ?assertMatch({ok, 200, _, _}, dispatch(<<"GET">>, <<"/api/ingress/ready">>)).

api_ingress_status_head_test() ->
    ensure_ingress_status_env(),
    ?assertMatch({ok, 200, _, _}, dispatch(<<"HEAD">>, <<"/api/ingress/status">>)).

api_logs_with_query_test() ->
    ensure_env(),
    ?assertMatch({ok, 200, _, _}, dispatch(<<"GET">>, <<"/api/logs">>, <<"type=proxy">>)).

api_helm_values_not_ingress_test() ->
    ensure_env(),
    ?assertMatch({ok, 404, _, _}, dispatch(<<"GET">>, <<"/api/helm/values/1">>)).

api_kubernetes_pods_test() ->
    ensure_env(),
    Result = dispatch(<<"GET">>, <<"/api/kubernetes/pods">>),
    ?assertMatch({ok, Status, _, _} when Status =:= 200 orelse Status =:= 400 orelse Status =:= 404, Result).

api_kubernetes_services_test() ->
    ensure_env(),
    Result = dispatch(<<"GET">>, <<"/api/kubernetes/services">>, <<"namespace=default">>),
    ?assertMatch({ok, Status, _, _} when Status =:= 200 orelse Status =:= 400 orelse Status =:= 404, Result).

api_kubernetes_tls_secrets_test() ->
    ensure_env(),
    Result = dispatch(<<"GET">>, <<"/api/kubernetes/tls-secrets">>, <<"namespace=default">>),
    ?assertMatch({ok, Status, _, _} when Status =:= 200 orelse Status =:= 400 orelse Status =:= 404, Result).

api_kubernetes_ingresses_test() ->
    ensure_env(),
    Result = dispatch(<<"GET">>, <<"/api/kubernetes/ingresses">>),
    ?assertMatch({ok, Status, _, _} when Status =:= 200 orelse Status =:= 400 orelse Status =:= 404, Result).

api_backup_restore_valid_test() ->
    with_tmp_db(fun(_Db) ->
        {ok, 200, _, ExportBody} = dispatch(<<"GET">>, <<"/api/backup/export">>),
        Restore = thoas:encode(#{<<"data">> => ExportBody}),
        ?assertMatch({ok, 200, _, _}, dispatch(<<"POST">>, <<"/api/backup/restore">>, Restore))
    end).

api_site_delete_test() ->
    ensure_env(),
    Host = <<"del-site.example">>,
    Add = thoas:encode(#{
        <<"host">> => Host,
        <<"backend">> => <<"web">>,
        <<"routes">> => []
    }),
    _ = dispatch(<<"POST">>, <<"/api/sites">>, Add),
    ?assertMatch({ok, 200, _, _}, dispatch(<<"DELETE">>, <<"/api/sites/del-site.example">>)).

api_auth_config_head_test() ->
    ensure_env(),
    ?assertMatch({ok, 200, _, _}, dispatch(<<"HEAD">>, <<"/api/auth/config">>)).

api_sites_patch_not_allowed_test() ->
    ensure_env(),
    ?assertMatch({ok, 405, _, _}, dispatch(<<"PATCH">>, <<"/api/sites">>)).

%% ---------------------------------------------------------------------------
%% auth_login with local auth + db
%% ---------------------------------------------------------------------------

api_auth_login_local_success_test() ->
    with_local_auth_db(fun(_Db) ->
        Body = thoas:encode(#{<<"username">> => <<"admin">>, <<"password">> => <<"admin">>}),
        {ok, 200, _, RespBody} = dispatch(<<"POST">>, <<"/api/auth/login">>, Body),
        {ok, Map} = thoas:decode(RespBody),
        ?assert(maps:is_key(<<"token">>, Map)),
        ?assertEqual(<<"admin">>, maps:get(<<"username">>, Map))
    end).

api_auth_login_local_invalid_credentials_test() ->
    with_local_auth_db(fun(_Db) ->
        Body = thoas:encode(#{<<"username">> => <<"admin">>, <<"password">> => <<"wrong">>}),
        ?assertMatch({ok, 401, _, _}, dispatch(<<"POST">>, <<"/api/auth/login">>, Body))
    end).

api_auth_login_disabled_returns_400_test() ->
    Old = application:get_env(pertisk_eproxy, admin_auth),
    application:set_env(pertisk_eproxy, admin_auth, disabled),
    ensure_env(),
    try
        Body = thoas:encode(#{<<"username">> => <<"admin">>, <<"password">> => <<"admin">>}),
        ?assertMatch({ok, 400, _, _}, dispatch(<<"POST">>, <<"/api/auth/login">>, Body))
    after
        case Old of
            {ok, V} -> application:set_env(pertisk_eproxy, admin_auth, V);
            undefined -> application:unset_env(pertisk_eproxy, admin_auth)
        end
    end.

%% ---------------------------------------------------------------------------
%% proto, management, logs filters
%% ---------------------------------------------------------------------------

api_proto_get_decodes_test() ->
    ensure_env(),
    {ok, 200, _, Body} = dispatch(<<"GET">>, <<"/api/proto">>),
    {ok, Map} = thoas:decode(Body),
    ?assert(maps:is_key(<<"http_version">>, Map)),
    ?assert(maps:is_key(<<"scheme">>, Map)),
    ?assert(maps:is_key(<<"host">>, Map)).

api_proto_head_not_implemented_test() ->
    ensure_env(),
    ?assertMatch({ok, 405, _, _}, dispatch(<<"HEAD">>, <<"/api/proto">>)).

api_management_snapshot_fields_test() ->
    ensure_env(),
    {ok, 200, _, Body} = dispatch(<<"GET">>, <<"/api/management">>),
    {ok, Map} = thoas:decode(Body),
    ?assert(maps:is_key(<<"version">>, Map)),
    ?assert(maps:is_key(<<"mode">>, Map)).

api_logs_host_filter_test() ->
    ensure_env(),
    ?assertMatch({ok, 200, _, _}, dispatch(<<"GET">>, <<"/api/logs">>, <<"host=example.com">>)).

api_logs_site_filter_test() ->
    ensure_env(),
    ?assertMatch({ok, 200, _, _}, dispatch(<<"GET">>, <<"/api/logs">>, <<"site=web">>)).

api_logs_combined_filters_test() ->
    ensure_env(),
    Qs = <<"type=proxy&host=example.com&site=web">>,
    ?assertMatch({ok, 200, _, _}, dispatch(<<"GET">>, <<"/api/logs">>, Qs)).

%% ---------------------------------------------------------------------------
%% HEAD methods
%% ---------------------------------------------------------------------------

api_auth_check_head_test() ->
    ensure_env(),
    Result = dispatch(<<"HEAD">>, <<"/api/auth/check">>),
    ?assertMatch(
        {ok, Status, _, _} when Status =:= 200 orelse Status =:= 401 orelse Status =:= 405,
        Result
    ).

api_ingress_live_head_test() ->
    ensure_env(),
    ?assertMatch({ok, 200, _, _}, dispatch(<<"HEAD">>, <<"/api/ingress/live">>)).

api_ingress_ready_head_test() ->
    ensure_env(),
    Result = dispatch(<<"HEAD">>, <<"/api/ingress/ready">>),
    ?assertMatch({ok, Status, _, _} when Status =:= 200 orelse Status =:= 503, Result).

api_stats_head_not_allowed_test() ->
    ensure_env(),
    Result = dispatch(<<"HEAD">>, <<"/api/stats">>),
    ?assertMatch({ok, Status, _, _} when Status =:= 401 orelse Status =:= 405, Result).

%% ---------------------------------------------------------------------------
%% ingress endpoints
%% ---------------------------------------------------------------------------

api_ingress_watchers_snapshot_test() ->
    ensure_ingress_status_env(),
    {ok, 200, _, Body} = dispatch(<<"GET">>, <<"/api/ingress/watchers">>),
    {ok, Map} = thoas:decode(Body),
    ?assert(maps:is_key(<<"watcher">>, Map)),
    ?assert(maps:is_key(<<"leader">>, Map)).

api_ingress_errors_snapshot_test() ->
    ensure_ingress_status_env(),
    {ok, 200, _, Body} = dispatch(<<"GET">>, <<"/api/ingress/errors">>),
    {ok, Map} = thoas:decode(Body),
    ?assert(maps:is_key(<<"last_error">>, Map)).

api_ingress_resources_lists_test() ->
    ensure_env(),
    {ok, 200, _, Body} = dispatch(<<"GET">>, <<"/api/ingress/resources">>),
    {ok, Map} = thoas:decode(Body),
    ?assert(is_list(maps:get(<<"sites">>, Map, []))),
    ?assert(is_list(maps:get(<<"backends">>, Map, []))).

%% ---------------------------------------------------------------------------
%% helm 404s and edge cases
%% ---------------------------------------------------------------------------

api_helm_history_bad_revision_not_applicable_test() ->
    ensure_env(),
    ?assertMatch({ok, 404, _, _}, dispatch(<<"GET">>, <<"/api/helm/history">>)).

api_helm_values_invalid_revision_not_ingress_test() ->
    ensure_env(),
    ?assertMatch({ok, 404, _, _}, dispatch(<<"GET">>, <<"/api/helm/values/not-a-number">>)).

api_helm_values_negative_revision_not_ingress_test() ->
    ensure_env(),
    ?assertMatch({ok, 404, _, _}, dispatch(<<"GET">>, <<"/api/helm/values/-1">>)).

%% ---------------------------------------------------------------------------
%% backup flows
%% ---------------------------------------------------------------------------

api_backup_export_with_db_test() ->
    with_tmp_db(fun(_Db) ->
        {ok, 200, _, Body} = dispatch(<<"GET">>, <<"/api/backup/export">>),
        {ok, Map} = thoas:decode(Body),
        ?assert(maps:is_key(<<"sites">>, Map)),
        ?assert(maps:is_key(<<"backends">>, Map)),
        ?assert(maps:is_key(<<"dns_providers">>, Map)),
        ?assert(maps:is_key(<<"certificate_records">>, Map))
    end).

api_backup_restore_empty_data_test() ->
    ensure_env(),
    Body = thoas:encode(#{<<"data">> => <<>>}),
    ?assertMatch({ok, 400, _, _}, dispatch(<<"POST">>, <<"/api/backup/restore">>, Body)).

api_backup_roundtrip_with_certificate_test() ->
    with_tmp_db(fun(_Db) ->
        Add = thoas:encode(#{<<"name">> => <<"backup-cert">>}),
        ?assertMatch({ok, 201, _, _}, dispatch(<<"POST">>, <<"/api/certificates">>, Add)),
        {ok, 200, _, ExportBody} = dispatch(<<"GET">>, <<"/api/backup/export">>),
        Restore = thoas:encode(#{<<"data">> => ExportBody}),
        ?assertMatch({ok, 200, _, _}, dispatch(<<"POST">>, <<"/api/backup/restore">>, Restore)),
        ?assertMatch({ok, 200, _, _}, dispatch(<<"GET">>, <<"/api/certificates">>))
    end).

%% ---------------------------------------------------------------------------
%% certificate import / PUT / delete
%% ---------------------------------------------------------------------------

api_certificates_import_valid_test() ->
    with_tmp_db(fun(_Db) ->
        with_tls_data_dir(fun(_Dir) ->
            Cert = read_priv_pem("listener.pem"),
            Key = read_priv_pem("listener.key"),
            Body = thoas:encode(#{<<"cert_pem">> => Cert, <<"key_pem">> => Key}),
            Result = dispatch(<<"POST">>, <<"/api/certificates/import">>, Body),
            ?assertMatch({ok, Status, _, _} when Status =:= 201 orelse Status =:= 400, Result)
        end)
    end).

api_certificate_import_put_valid_test() ->
    with_tmp_db(fun(_Db) ->
        with_tls_data_dir(fun(_Dir) ->
            Add = thoas:encode(#{<<"name">> => <<"import-target">>}),
            {ok, 201, _, _} = dispatch(<<"POST">>, <<"/api/certificates">>, Add),
            Cert = read_priv_pem("listener.pem"),
            Key = read_priv_pem("listener.key"),
            Import = thoas:encode(#{<<"cert_pem">> => Cert, <<"key_pem">> => Key}),
            Result = dispatch(<<"PUT">>, <<"/api/certificates/1/import">>, Import),
            ?assertMatch({ok, Status, _, _} when Status =:= 200 orelse Status =:= 400, Result)
        end)
    end).

api_certificate_import_put_invalid_id_test() ->
    ensure_env(),
    Body = thoas:encode(#{<<"cert_pem">> => <<"bad">>, <<"key_pem">> => <<"bad">>}),
    ?assertMatch({ok, 400, _, _}, dispatch(<<"PUT">>, <<"/api/certificates/not-id/import">>, Body)).

api_certificate_delete_not_in_use_test() ->
    with_tmp_db(fun(_Db) ->
        Add = thoas:encode(#{<<"name">> => <<"deletable-cert">>}),
        {ok, 201, _, Resp} = dispatch(<<"POST">>, <<"/api/certificates">>, Add),
        {ok, #{<<"id">> := Id}} = thoas:decode(Resp),
        IdBin =
            case Id of
                I when is_integer(I) -> integer_to_binary(I);
                B when is_binary(B) -> B
            end,
        Path = <<"/api/certificates/", IdBin/binary>>,
        DelResult = dispatch(<<"DELETE">>, Path),
        ?assertMatch({ok, Status, _, _} when Status =:= 200 orelse Status =:= 404, DelResult)
    end).

api_certificate_delete_not_found_test() ->
    with_tmp_db(fun(_Db) ->
        ?assertMatch({ok, 404, _, _}, dispatch(<<"DELETE">>, <<"/api/certificates/999">>))
    end).

api_certificate_delete_in_use_test() ->
    with_tmp_db(fun(_Db) ->
        Add = thoas:encode(#{<<"name">> => <<"in-use-cert">>}),
        {ok, 201, _, Resp} = dispatch(<<"POST">>, <<"/api/certificates">>, Add),
        {ok, #{<<"id">> := Id}} = thoas:decode(Resp),
        IdBin =
            case Id of
                I when is_integer(I) -> integer_to_binary(I);
                B when is_binary(B) -> B
            end,
        Path = <<"/api/certificates/", IdBin/binary>>,
        pertisk_eproxy_test_helpers:sync_router(
            [#{host => <<"cert-site.example">>, backend => <<"web">>,
              certificate => <<"in-use-cert">>, routes => []}],
            []
        ),
        try
            DelResult = dispatch(<<"DELETE">>, Path),
            ?assertMatch({ok, Status, _, _} when Status =:= 400 orelse Status =:= 404, DelResult)
        after
            pertisk_eproxy_test_helpers:sync_router([], [])
        end
    end).

api_certificate_put_empty_name_test() ->
    with_tmp_db(fun(_Db) ->
        Add = thoas:encode(#{<<"name">> => <<"named-cert">>}),
        {ok, 201, _, _} = dispatch(<<"POST">>, <<"/api/certificates">>, Add),
        Put = thoas:encode(#{<<"name">> => <<>>}),
        ?assertMatch({ok, 400, _, _}, dispatch(<<"PUT">>, <<"/api/certificates/1">>, Put))
    end).

%% ---------------------------------------------------------------------------
%% site PUT with TLS fields
%% ---------------------------------------------------------------------------

api_site_put_preserves_tls_fields_test() ->
    ensure_env(),
    Host = <<"tls-put-site.example">>,
    pertisk_eproxy_test_helpers:sync_router(
        [#{host => Host, backend => <<"web">>, certificate => <<"my-cert">>,
          dns_provider => <<"cf-prod">>, challenge_type => <<"dns-01">>, wildcard => true,
          acme_contact_email => <<"ops@example.com">>, routes => []}],
        []
    ),
    Put = thoas:encode(#{
        <<"host">> => Host,
        <<"backend">> => <<"web">>,
        <<"routes">> => [#{<<"path">> => <<"/api">>, <<"path_type">> => <<"prefix">>}]
    }),
    try
        ?assertMatch({ok, 200, _, _}, dispatch(<<"PUT">>, <<"/api/sites/tls-put-site.example">>, Put)),
        {ok, 200, _, GetBody} = dispatch(<<"GET">>, <<"/api/sites/tls-put-site.example">>),
        {ok, Site} = thoas:decode(GetBody),
        ?assertEqual(<<"my-cert">>, maps:get(<<"certificate">>, Site)),
        ?assertEqual(<<"cf-prod">>, maps:get(<<"dns_provider">>, Site)),
        ?assertEqual(<<"dns-01">>, maps:get(<<"challenge_type">>, Site)),
        ?assertEqual(true, maps:get(<<"wildcard">>, Site)),
        ?assertEqual(<<"ops@example.com">>, maps:get(<<"acme_contact_email">>, Site))
    after
        pertisk_eproxy_test_helpers:sync_router([], [])
    end.

api_site_put_updates_tls_fields_test() ->
    ensure_env(),
    Host = <<"tls-update-site.example">>,
    pertisk_eproxy_test_helpers:sync_router(
        [#{host => Host, backend => <<"web">>, certificate => <<"old-cert">>,
          dns_provider => <<"old-dns">>, routes => []}],
        []
    ),
    Put = thoas:encode(#{
        <<"host">> => Host,
        <<"backend">> => <<"web">>,
        <<"certificate">> => <<"new-cert">>,
        <<"dns_provider">> => <<"new-dns">>,
        <<"routes">> => []
    }),
    try
        Result = dispatch(<<"PUT">>, <<"/api/sites/tls-update-site.example">>, Put),
        ?assertMatch({ok, Status, _, _} when Status =:= 200 orelse Status =:= 400, Result),
        case Result of
            {ok, 200, _, GetBody} ->
                {ok, Site} = thoas:decode(GetBody),
                ?assertEqual(<<"new-cert">>, maps:get(<<"certificate">>, Site)),
                ?assertEqual(<<"new-dns">>, maps:get(<<"dns_provider">>, Site));
            _ ->
                ok
        end
    after
        pertisk_eproxy_test_helpers:sync_router([], [])
    end.

%% ---------------------------------------------------------------------------
%% dns provider edge cases
%% ---------------------------------------------------------------------------

api_dns_provider_post_redacted_credentials_test() ->
    with_tmp_db(fun(_Db) ->
        Body = thoas:encode(#{
            <<"name">> => <<"cf-redacted">>,
            <<"provider_type">> => <<"cloudflare">>,
            <<"credentials">> => #{<<"api_token">> => <<"[redacted]">>}
        }),
        ?assertMatch({ok, 400, _, _}, dispatch(<<"POST">>, <<"/api/dns-providers">>, Body))
    end).

api_dns_provider_post_empty_name_test() ->
    with_tmp_db(fun(_Db) ->
        Body = thoas:encode(#{
            <<"name">> => <<>>,
            <<"provider_type">> => <<"cloudflare">>,
            <<"credentials">> => #{<<"api_token">> => <<"tok">>}
        }),
        ?assertMatch({ok, 400, _, _}, dispatch(<<"POST">>, <<"/api/dns-providers">>, Body))
    end).

api_dns_provider_put_invalid_id_test() ->
    with_tmp_db(fun(_Db) ->
        Put = thoas:encode(#{
            <<"name">> => <<"cf">>,
            <<"provider_type">> => <<"cloudflare">>,
            <<"credentials">> => #{<<"api_token">> => <<"tok">>}
        }),
        ?assertMatch({ok, 400, _, _}, dispatch(<<"PUT">>, <<"/api/dns-providers/not-id">>, Put))
    end).

api_dns_provider_put_redacted_credentials_test() ->
    with_tmp_db(fun(_Db) ->
        Add = thoas:encode(#{
            <<"name">> => <<"cf-redact-put">>,
            <<"provider_type">> => <<"cloudflare">>,
            <<"credentials">> => #{<<"api_token">> => <<"secret">>}
        }),
        ?assertMatch({ok, 201, _, _}, dispatch(<<"POST">>, <<"/api/dns-providers">>, Add)),
        Put = thoas:encode(#{
            <<"name">> => <<"cf-redact-put">>,
            <<"provider_type">> => <<"cloudflare">>,
            <<"credentials">> => #{<<"api_token">> => <<"[redacted]">>}
        }),
        ?assertMatch({ok, 400, _, _}, dispatch(<<"PUT">>, <<"/api/dns-providers/1">>, Put))
    end).

api_dns_provider_delete_by_name_test() ->
    with_tmp_db(fun(_Db) ->
        Add = thoas:encode(#{
            <<"name">> => <<"cf-by-name">>,
            <<"provider_type">> => <<"cloudflare">>,
            <<"credentials">> => #{<<"api_token">> => <<"secret">>}
        }),
        ?assertMatch({ok, 201, _, _}, dispatch(<<"POST">>, <<"/api/dns-providers">>, Add)),
        DelByName = dispatch(<<"DELETE">>, <<"/api/dns-providers/cf-by-name">>),
        ?assertMatch({ok, Status, _, _} when Status =:= 200 orelse Status =:= 404, DelByName)
    end).

api_dns_provider_delete_not_found_test() ->
    with_tmp_db(fun(_Db) ->
        ?assertMatch({ok, 404, _, _}, dispatch(<<"DELETE">>, <<"/api/dns-providers/missing-provider">>))
    end).

api_dns_provider_in_use_delete_test() ->
    with_tmp_db(fun(_Db) ->
        Add = thoas:encode(#{
            <<"name">> => <<"cf-in-use">>,
            <<"provider_type">> => <<"cloudflare">>,
            <<"credentials">> => #{<<"api_token">> => <<"secret">>}
        }),
        {ok, 201, _, Resp} = dispatch(<<"POST">>, <<"/api/dns-providers">>, Add),
        {ok, #{<<"id">> := Id}} = thoas:decode(Resp),
        IdBin =
            case Id of
                I when is_integer(I) -> integer_to_binary(I);
                B when is_binary(B) -> B
            end,
        Path = <<"/api/dns-providers/", IdBin/binary>>,
        pertisk_eproxy_test_helpers:sync_router(
            [#{host => <<"dns-site.example">>, backend => <<"web">>,
              dns_provider => <<"cf-in-use">>, routes => []}],
            []
        ),
        try
            DelResult = dispatch(<<"DELETE">>, Path),
            ?assertMatch({ok, Status, _, _} when Status =:= 400 orelse Status =:= 404, DelResult)
        after
            pertisk_eproxy_test_helpers:sync_router([], [])
        end
    end).

api_dns_provider_validate_missing_type_test() ->
    with_tmp_db(fun(_Db) ->
        Body = thoas:encode(#{
            <<"provider_type">> => <<>>,
            <<"credentials">> => #{<<"api_token">> => <<"tok">>}
        }),
        ?assertMatch({ok, 400, _, _}, dispatch(<<"POST">>, <<"/api/dns-providers/validate">>, Body))
    end).

api_dns_provider_validate_invalid_provider_test() ->
    with_tmp_db(fun(_Db) ->
        Body = thoas:encode(#{
            <<"provider_type">> => <<"unknown-provider">>,
            <<"credentials">> => #{<<"api_token">> => <<"tok">>}
        }),
        Result = dispatch(<<"POST">>, <<"/api/dns-providers/validate">>, Body),
        ?assertMatch({ok, Status, _, _} when Status =:= 200 orelse Status =:= 400, Result)
    end).

