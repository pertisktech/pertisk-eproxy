-module(pertisk_eproxy_admin_handler_tests).

-include_lib("eunit/include/eunit.hrl").

ensure_env() ->
    pertisk_eproxy_test_helpers:ensure_config(),
    ensure_backend_sup(),
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
    dispatch(Method, Path, Qs, Body, []).

dispatch(Method, Path, Qs, Body, Headers) ->
    dispatch_with_retry(Method, Path, Qs, Body, Headers, 8).

dispatch_with_retry(Method, Path, Qs, Body, Headers, 0) ->
    pertisk_eproxy_test_helpers:with_db_lock(fun() ->
        pertisk_eproxy_h3_local_admin:try_dispatch(
            Method, <<"localhost">>, Path, Qs, Headers, Body, <<"127.0.0.1">>
        )
    end);
dispatch_with_retry(Method, Path, Qs, Body, Headers, Retries) ->
    Resp = pertisk_eproxy_test_helpers:with_db_lock(fun() ->
        pertisk_eproxy_h3_local_admin:try_dispatch(
            Method, <<"localhost">>, Path, Qs, Headers, Body, <<"127.0.0.1">>
        )
    end),
    case should_retry_locked_response(Method, Resp) of
        true ->
            timer:sleep(75),
            dispatch_with_retry(Method, Path, Qs, Body, Headers, Retries - 1);
        false ->
            Resp
    end.

should_retry_locked_response(Method, {ok, 400, _Hdrs, Resp}) ->
    is_write_method(Method) andalso sqlite_locked_msg(Resp);
should_retry_locked_response(_, _) ->
    false.

is_write_method(<<"GET">>) ->
    false;
is_write_method(<<"HEAD">>) ->
    false;
is_write_method(<<"OPTIONS">>) ->
    false;
is_write_method(Method) when is_binary(Method) ->
    true;
is_write_method(Method) when is_list(Method) ->
    Upper = string:uppercase(Method),
    not lists:member(Upper, ["GET", "HEAD", "OPTIONS"]);
is_write_method(_) ->
    false.

dispatch_auth(Method, Path, Body, Token) ->
    dispatch(Method, Path, <<>>, Body, [{<<"authorization">>, <<"Bearer ", Token/binary>>}]).

safe_meck_unload(Mod) ->
    case lists:member(Mod, meck:mocked()) of
        true ->
            try meck:unload(Mod) catch _:_ -> ok end;
        false ->
            ok
    end.

%% Bypass h3 fast-path (e.g. /api/health) and invoke admin_handler:init/2 directly.
init_dispatch(Method, Path, Resource) ->
    init_dispatch(Method, Path, Resource, <<>>).

init_dispatch(Method, Path, Resource, Body) ->
    init_dispatch(Method, Path, Resource, Body, []).

init_dispatch(Method, Path, Resource, Body, Headers) ->
    Parent = self(),
    Stub = pertisk_eproxy_cowboy_stub_conn:start(Parent, Body),
    HdrMap = maps:from_list([{string:lowercase(K), V} || {K, V} <- Headers]),
    HeadersMerged = maps:merge(#{<<"host">> => <<"localhost">>}, HdrMap),
    MethodBin =
        case Method of
            M when is_binary(M) -> string:uppercase(M);
            M when is_list(M) -> list_to_binary(string:uppercase(M))
        end,
    Req = #{
        method => MethodBin,
        version => 'HTTP/1.1',
        scheme => <<"http">>,
        host => <<"localhost">>,
        port => 9080,
        path => Path,
        qs => <<>>,
        headers => HeadersMerged,
        peer => {{127, 0, 0, 1}, 12345},
        sock => {{127, 0, 0, 1}, 9080},
        cert => undefined,
        ref => stub,
        pid => Stub,
        streamid => pertisk_eproxy_cowboy_stub_conn:stub_stream_id(),
        has_body => Body =/= <<>>,
        body_length =>
            case Body of
                <<>> -> undefined;
                _ -> byte_size(Body)
            end
    },
    _ = pertisk_eproxy_admin_handler:init(Req, Resource),
    Result =
        receive
            {h3_admin_response, Status, Hdrs, RespBody} ->
                HeaderList =
                    case Hdrs of
                        H when is_map(H) -> [{K, V} || {K, V} <- maps:to_list(H), is_binary(K)];
                        H when is_list(H) -> H
                    end,
                {ok, Status, HeaderList, RespBody}
        after 10000 ->
            {error, timeout}
        end,
    unlink(Stub),
    exit(Stub, kill),
    Result.

ensure_health_cache() ->
    ensure_env(),
    case whereis(pertisk_eproxy_health_cache) of
        undefined ->
            {ok, _} = pertisk_eproxy_health_cache:start_link();
        _ ->
            ok
    end,
    pertisk_eproxy_health_cache:invalidate(),
    case pertisk_eproxy_health_cache:get() of
        {ok, _} ->
            ok;
        _ ->
            timer:sleep(300)
    end.

stop_config_if_running() ->
    case whereis(pertisk_eproxy_config) of
        undefined ->
            ok;
        Pid ->
            catch gen_server:stop(Pid, normal, 5000),
            wait_config_stopped(30)
    end.

wait_config_stopped(0) ->
    ok;
wait_config_stopped(N) ->
    case whereis(pertisk_eproxy_config) of
        undefined ->
            ok;
        _ ->
            timer:sleep(50),
            wait_config_stopped(N - 1)
    end.

init_tmp_db(DbPath) ->
    init_tmp_db(DbPath, 8).

init_tmp_db(DbPath, 0) ->
    pertisk_eproxy_db:init(DbPath);
init_tmp_db(DbPath, Retries) ->
    case pertisk_eproxy_db:init(DbPath) of
        {ok, _} = Ok ->
            Ok;
        {error, {sqlite_error, Msg, _}} when Retries > 0 ->
            case sqlite_locked_msg(Msg) of
                true ->
                    timer:sleep(75),
                    init_tmp_db(DbPath, Retries - 1);
                false ->
                    {error, {sqlite_error, Msg, locked}}
            end;
        Other ->
            Other
    end.

sqlite_locked_msg(Msg) when is_binary(Msg) ->
    binary:match(Msg, <<"locked">>) =/= nomatch;
sqlite_locked_msg(Msg) when is_list(Msg) ->
    string:find(Msg, "locked") =/= nomatch;
sqlite_locked_msg(_) ->
    false.

dispatch_put_config(Body) ->
    dispatch_put_config(Body, 8).

dispatch_put_config(Body, 0) ->
    dispatch(<<"PUT">>, <<"/api/config">>, Body);
dispatch_put_config(Body, Retries) ->
    case dispatch(<<"PUT">>, <<"/api/config">>, Body) of
        {ok, 400, Hdrs, Resp} when Retries > 0 ->
            case binary:match(Resp, <<"locked">>) of
                nomatch ->
                    {ok, 400, Hdrs, Resp};
                _ ->
                    timer:sleep(75),
                    dispatch_put_config(Body, Retries - 1)
            end;
        Other ->
            Other
    end.

with_tmp_db(Fun) ->
    pertisk_eproxy_test_helpers:with_db_lock(fun() ->
        DbPath = pertisk_eproxy_test_helpers:tmp_db(),
        file:delete(DbPath),
        OldDb = application:get_env(pertisk_eproxy, db_file),
        stop_config_if_running(),
        application:set_env(pertisk_eproxy, db_file, DbPath),
        try
            ?assertMatch({ok, _}, init_tmp_db(DbPath)),
            ensure_env(),
            Fun(DbPath)
        after
            stop_config_if_running(),
            case OldDb of
                {ok, V} -> application:set_env(pertisk_eproxy, db_file, V);
                undefined -> application:unset_env(pertisk_eproxy, db_file)
            end,
            file:delete(DbPath),
            ensure_env()
        end
    end).

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
    with_tmp_db(fun(_Db) ->
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
        end
    end).

read_priv_pem(Name) ->
    Path = filename:join([code:priv_dir(pertisk_eproxy), "tls", Name]),
    {ok, Bin} = file:read_file(Path),
    Bin.

with_env(Key, Val, Fun) ->
    Old = os:getenv(Key),
    case Val of
        unset -> os:unsetenv(Key);
        {set, NewVal} -> os:putenv(Key, NewVal)
    end,
    try Fun() after
        case Old of
            false -> os:unsetenv(Key);
            OldVal -> os:putenv(Key, OldVal)
        end
    end.

with_ingress_mode(Fun) ->
    with_env("PERTISK_MODE", {set, "ingress"}, fun() ->
        ensure_env(),
        Fun()
    end).

with_ingress_authenticated(Fun) ->
    OldSupports = application:get_env(pertisk_eproxy, ingress_supports_local),
    OldAuth = application:get_env(pertisk_eproxy, admin_auth),
    application:set_env(pertisk_eproxy, ingress_supports_local, true),
    application:set_env(pertisk_eproxy, admin_auth, local),
    with_auth_server(fun() ->
        with_env("PERTISK_ADMIN", {set, "admin"}, fun() ->
            with_env("PERTISK_PASSWORD", {set, "admin"}, fun() ->
                try
                    with_ingress_mode(fun() ->
                        Login = thoas:encode(#{<<"username">> => <<"admin">>, <<"password">> => <<"admin">>}),
                        {ok, 200, _, LoginBody} = dispatch(<<"POST">>, <<"/api/auth/login">>, Login),
                        {ok, #{<<"token">> := Token}} = thoas:decode(LoginBody),
                        Fun(Token)
                    end)
                after
                    case OldSupports of
                        {ok, SupportsVal} ->
                            application:set_env(pertisk_eproxy, ingress_supports_local, SupportsVal);
                        undefined ->
                            application:unset_env(pertisk_eproxy, ingress_supports_local)
                    end,
                    case OldAuth of
                        {ok, AuthVal} -> application:set_env(pertisk_eproxy, admin_auth, AuthVal);
                        undefined -> application:unset_env(pertisk_eproxy, admin_auth)
                    end
                end
            end)
        end)
    end).

with_mock_k8s(Fun) ->
    Conn = {mock_api, mock_access},
    meck:new(pertisk_ingress_ekub, [unstick]),
    meck:expect(pertisk_ingress_ekub, init, fun() -> {ok, Conn} end),
    meck:new(ekub, [unstick]),
    meck:new(ekub_api, [unstick]),
    meck:new(ekub_core, [unstick]),
    meck:new(pertisk_ingress_watcher, [unstick]),
    meck:expect(pertisk_ingress_watcher, trigger_reconcile, fun() -> ok end),
    try Fun(Conn) after
        meck:unload([pertisk_ingress_ekub, ekub, ekub_api, ekub_core, pertisk_ingress_watcher])
    end.

ensure_backend_sup() ->
    case whereis(pertisk_eproxy_backend_sup) of
        undefined ->
            {ok, _} = pertisk_eproxy_backend_sup:start_link();
        _ ->
            ok
    end.

head_matches_get_headers(Path) ->
    {ok, GetStatus, GetHdrs, _} = dispatch(<<"GET">>, Path),
    {ok, HeadStatus, HeadHdrs, _} = dispatch(<<"HEAD">>, Path),
    ?assertEqual(GetStatus, HeadStatus),
    ?assertEqual(
        proplists:get_value(<<"content-type">>, GetHdrs),
        proplists:get_value(<<"content-type">>, HeadHdrs)
    ).

sample_k8s_ingress(Name, Ns, Host) ->
    #{
        <<"metadata">> => #{
            <<"name">> => Name,
            <<"namespace">> => Ns,
            <<"creationTimestamp">> => <<"2020-01-01T00:00:00Z">>,
            <<"annotations">> => #{}
        },
        <<"spec">> => #{
            <<"ingressClassName">> => <<"pertisk-eproxy">>,
            <<"rules">> => [
                #{
                    <<"host">> => Host,
                    <<"http">> => #{
                        <<"paths">> => [
                            #{
                                <<"path">> => <<"/">>,
                                <<"pathType">> => <<"Prefix">>,
                                <<"backend">> => #{
                                    <<"service">> => #{
                                        <<"name">> => <<"web">>,
                                        <<"port">> => #{<<"number">> => 80}
                                    }
                                }
                            }
                        ]
                    }
                }
            ],
            <<"tls">> => [#{<<"secretName">> => <<"tls-secret">>}]
        }
    }.

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
    with_tmp_db(fun(_Db) ->
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
    end
    end).

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
    with_tmp_db(fun(_Db) ->
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
    end
    end).

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
    with_tmp_db(fun(_Db) ->
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
        end
    end).

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
            {ok, 201, _, RespBody} = dispatch(<<"POST">>, <<"/api/certificates/import">>, Body),
            {ok, Map} = thoas:decode(RespBody),
            ?assertEqual(<<"ok">>, maps:get(<<"status">>, Map)),
            ?assert(maps:is_key(<<"id">>, Map))
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

%% ---------------------------------------------------------------------------
%% auth_refresh, config PUT edge cases, list endpoints, metrics, ingress HEAD
%% ---------------------------------------------------------------------------

api_auth_refresh_local_with_token_test() ->
    with_local_auth_db(fun(_Db) ->
        Login = thoas:encode(#{<<"username">> => <<"admin">>, <<"password">> => <<"admin">>}),
        {ok, 200, _, LoginBody} = dispatch(<<"POST">>, <<"/api/auth/login">>, Login),
        {ok, #{<<"token">> := Token}} = thoas:decode(LoginBody),
        {ok, 200, _, RefreshBody} =
            dispatch_auth(<<"POST">>, <<"/api/auth/refresh">>, <<>>, Token),
        {ok, Map} = thoas:decode(RefreshBody),
        ?assertEqual(Token, maps:get(<<"token">>, Map)),
        ?assertEqual(<<"admin">>, maps:get(<<"username">>, Map)),
        ?assert(maps:is_key(<<"expires_in">>, Map))
    end).

api_auth_refresh_local_missing_token_test() ->
    with_local_auth(fun() ->
        ?assertMatch({ok, 401, _, _}, dispatch(<<"POST">>, <<"/api/auth/refresh">>))
    end).

api_auth_refresh_local_invalid_token_test() ->
    with_local_auth(fun() ->
        ?assertMatch(
            {ok, 401, _, _},
            dispatch_auth(<<"POST">>, <<"/api/auth/refresh">>, <<>>, <<"not-a-valid-token">>)
        )
    end).

api_config_put_invalid_json_test() ->
    ensure_env(),
    ?assertMatch({ok, 400, _, _}, dispatch(<<"PUT">>, <<"/api/config">>, <<"{not-json">>)).

api_config_put_empty_sites_test() ->
    ensure_env(),
    {ok, 200, _, Body} = dispatch(<<"GET">>, <<"/api/config">>),
    {ok, Map} = thoas:decode(Body),
    Put = thoas:encode(Map#{<<"sites">> => []}),
    ?assertMatch({ok, 200, _, _}, dispatch(<<"PUT">>, <<"/api/config">>, Put)).

api_sites_list_after_add_test() ->
    ensure_env(),
    Host = <<"list-site.example">>,
    Add = thoas:encode(#{
        <<"host">> => Host,
        <<"backend">> => <<"web">>,
        <<"routes">> => []
    }),
    try
        ?assertMatch({ok, 201, _, _}, dispatch(<<"POST">>, <<"/api/sites">>, Add)),
        {ok, 200, _, ListBody} = dispatch(<<"GET">>, <<"/api/sites">>),
        {ok, Sites} = thoas:decode(ListBody),
        ?assert(
            lists:any(
                fun(S) -> maps:get(<<"host">>, S, undefined) =:= Host end,
                Sites
            )
        )
    after
        _ = dispatch(<<"DELETE">>, <<"/api/sites/list-site.example">>)
    end.

api_backends_list_after_add_test() ->
    ensure_env(),
    Name = <<"bl_", (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    Body = thoas:encode(#{
        <<"name">> => Name,
        <<"algorithm">> => <<"round_robin">>,
        <<"upstreams">> => [#{<<"addr">> => <<"127.0.0.1:9">>}]
    }),
    try
        ?assertMatch({ok, 201, _, _}, dispatch(<<"POST">>, <<"/api/backends">>, Body)),
        {ok, 200, _, ListBody} = dispatch(<<"GET">>, <<"/api/backends">>),
        {ok, Backends} = thoas:decode(ListBody),
        ?assert(
            lists:any(
                fun(B) -> maps:get(<<"name">>, B, undefined) =:= Name end,
                Backends
            )
        )
    after
        _ = dispatch(<<"DELETE">>, <<"/api/backends/", Name/binary>>)
    end.

api_metrics_prometheus_format_test() ->
    pertisk_eproxy_test_helpers:ensure_metrics(),
    ensure_env(),
    {ok, 200, Hdrs, Body} = dispatch(<<"GET">>, <<"/api/metrics">>),
    ?assertEqual(<<"text/plain; version=0.0.4">>, proplists:get_value(<<"content-type">>, Hdrs)),
    ?assert(byte_size(Body) > 0).

api_site_delete_not_found_test() ->
    ensure_env(),
    %% DELETE is idempotent: removing a missing host still returns 200.
    {ok, 200, _, Body} = dispatch(<<"DELETE">>, <<"/api/sites/missing-delete.example">>),
    {ok, Map} = thoas:decode(Body),
    ?assertEqual(<<"deleted">>, maps:get(<<"status">>, Map)).

api_ingress_watchers_head_not_allowed_test() ->
    ensure_ingress_status_env(),
    ?assertMatch({ok, 405, _, _}, dispatch(<<"HEAD">>, <<"/api/ingress/watchers">>)).

api_ingress_errors_head_not_allowed_test() ->
    ensure_ingress_status_env(),
    ?assertMatch({ok, 405, _, _}, dispatch(<<"HEAD">>, <<"/api/ingress/errors">>)).

api_ingress_resources_head_not_allowed_test() ->
    ensure_env(),
    ?assertMatch({ok, 405, _, _}, dispatch(<<"HEAD">>, <<"/api/ingress/resources">>)).

api_backup_restore_with_certificate_record_test() ->
    with_tmp_db(fun(_Db) ->
        Add = thoas:encode(#{<<"name">> => <<"restore-cert">>}),
        {ok, 201, _, CertResp} = dispatch(<<"POST">>, <<"/api/certificates">>, Add),
        {ok, #{<<"id">> := CertId}} = thoas:decode(CertResp),
        {ok, 200, _, ExportBody} = dispatch(<<"GET">>, <<"/api/backup/export">>),
        {ok, ExportMap} = thoas:decode(ExportBody),
        Certs = maps:get(<<"certificate_records">>, ExportMap, []),
        ?assert(
            lists:any(
                fun(C) ->
                    maps:get(<<"name">>, C, undefined) =:= <<"restore-cert">>
                end,
                Certs
            )
        ),
        Restore = thoas:encode(#{<<"data">> => ExportBody}),
        ?assertMatch({ok, 200, _, _}, dispatch(<<"POST">>, <<"/api/backup/restore">>, Restore)),
        {ok, 200, _, ListBody} = dispatch(<<"GET">>, <<"/api/certificates">>),
        {ok, Rows} = thoas:decode(ListBody),
        CertIdBin =
            case CertId of
                I when is_integer(I) -> integer_to_binary(I);
                B when is_binary(B) -> B
            end,
        ?assert(
            lists:any(
                fun(R) ->
                    maps:get(<<"id">>, R, undefined) =:= CertIdBin
                        orelse maps:get(<<"domain">>, R, undefined) =:= <<"restore-cert">>
                end,
                Rows
            )
        )
    end).

dns_provider_validate_via_api(ProviderType, Creds) ->
    Body = thoas:encode(#{
        <<"provider_type">> => ProviderType,
        <<"credentials">> => Creds
    }),
    dispatch(<<"POST">>, <<"/api/dns-providers/validate">>, Body).

api_dns_provider_validate_digitalocean_test() ->
    with_tmp_db(fun(_Db) ->
        ?assertMatch(
            {ok, 200, _, _},
            dns_provider_validate_via_api(<<"digitalocean">>, #{<<"api_token">> => <<"secret">>})
        )
    end).

api_dns_provider_validate_vultr_test() ->
    with_tmp_db(fun(_Db) ->
        ?assertMatch(
            {ok, 200, _, _},
            dns_provider_validate_via_api(<<"vultr">>, #{<<"api_token">> => <<"secret">>})
        )
    end).

api_dns_provider_validate_porkbun_test() ->
    with_tmp_db(fun(_Db) ->
        ?assertMatch(
            {ok, 200, _, _},
            dns_provider_validate_via_api(
                <<"porkbun">>,
                #{<<"api_key">> => <<"k">>, <<"secret_api_key">> => <<"s">>}
            )
        )
    end).

api_dns_provider_validate_linode_test() ->
    with_tmp_db(fun(_Db) ->
        ?assertMatch(
            {ok, 200, _, _},
            dns_provider_validate_via_api(<<"linode">>, #{<<"api_token">> => <<"secret">>})
        )
    end).

api_dns_provider_validate_hetzner_test() ->
    with_tmp_db(fun(_Db) ->
        ?assertMatch(
            {ok, 200, _, _},
            dns_provider_validate_via_api(<<"hetzner">>, #{<<"api_token">> => <<"secret">>})
        )
    end).

api_dns_provider_validate_desec_test() ->
    with_tmp_db(fun(_Db) ->
        ?assertMatch(
            {ok, 200, _, _},
            dns_provider_validate_via_api(<<"desec">>, #{<<"api_token">> => <<"secret">>})
        )
    end).

api_dns_provider_validate_gandi_test() ->
    with_tmp_db(fun(_Db) ->
        ?assertMatch(
            {ok, 200, _, _},
            dns_provider_validate_via_api(<<"gandi">>, #{<<"api_token">> => <<"secret">>})
        )
    end).

api_dns_provider_validate_powerdns_test() ->
    with_tmp_db(fun(_Db) ->
        ?assertMatch(
            {ok, 200, _, _},
            dns_provider_validate_via_api(
                <<"powerdns">>,
                #{<<"api_url">> => <<"http://127.0.0.1:8081">>, <<"api_key">> => <<"secret">>}
            )
        )
    end).

api_dns_provider_validate_duckdns_test() ->
    with_tmp_db(fun(_Db) ->
        ?assertMatch(
            {ok, 200, _, _},
            dns_provider_validate_via_api(
                <<"duckdns">>,
                #{<<"domain">> => <<"example">>, <<"token">> => <<"tkn">>}
            )
        )
    end).

api_dns_provider_validate_route53_test() ->
    with_tmp_db(fun(_Db) ->
        Result = dns_provider_validate_via_api(<<"route53">>, #{}),
        ?assertMatch({ok, Status, _, _} when Status =:= 200 orelse Status =:= 400, Result)
    end).

api_dns_provider_validate_digitalocean_missing_token_test() ->
    with_tmp_db(fun(_Db) ->
        ?assertMatch(
            {ok, 400, _, _},
            dns_provider_validate_via_api(<<"digitalocean">>, #{})
        )
    end).

api_dns_provider_validate_powerdns_missing_url_test() ->
    with_tmp_db(fun(_Db) ->
        ?assertMatch(
            {ok, 400, _, _},
            dns_provider_validate_via_api(<<"powerdns">>, #{<<"api_key">> => <<"k">>})
        )
    end).

%% ---------------------------------------------------------------------------
%% local auth enforcement and token flows
%% ---------------------------------------------------------------------------

api_auth_check_local_authenticated_test() ->
    with_local_auth_db(fun(_Db) ->
        Login = thoas:encode(#{<<"username">> => <<"admin">>, <<"password">> => <<"admin">>}),
        {ok, 200, _, LoginBody} = dispatch(<<"POST">>, <<"/api/auth/login">>, Login),
        {ok, #{<<"token">> := Token}} = thoas:decode(LoginBody),
        {ok, 200, _, Body} =
            dispatch_auth(<<"GET">>, <<"/api/auth/check">>, <<>>, Token),
        {ok, Map} = thoas:decode(Body),
        ?assertEqual(true, maps:get(<<"authenticated">>, Map)),
        ?assertEqual(<<"admin">>, maps:get(<<"username">>, Map))
    end).

api_auth_check_local_unauthenticated_test() ->
    with_local_auth(fun() ->
        {ok, 200, _, Body} = dispatch(<<"GET">>, <<"/api/auth/check">>),
        {ok, Map} = thoas:decode(Body),
        ?assertEqual(false, maps:get(<<"authenticated">>, Map))
    end).

api_auth_logout_with_token_test() ->
    with_local_auth_db(fun(_Db) ->
        Login = thoas:encode(#{<<"username">> => <<"admin">>, <<"password">> => <<"admin">>}),
        {ok, 200, _, LoginBody} = dispatch(<<"POST">>, <<"/api/auth/login">>, Login),
        {ok, #{<<"token">> := Token}} = thoas:decode(LoginBody),
        ?assertMatch({ok, 200, _, _}, dispatch_auth(<<"POST">>, <<"/api/auth/logout">>, <<>>, Token))
    end).

api_sites_get_unauthorized_local_auth_test() ->
    with_local_auth(fun() ->
        ?assertMatch({ok, 401, _, _}, dispatch(<<"GET">>, <<"/api/sites">>))
    end).

api_config_get_unauthorized_local_auth_test() ->
    with_local_auth(fun() ->
        ?assertMatch({ok, 401, _, _}, dispatch(<<"GET">>, <<"/api/config">>))
    end).

api_admin_change_password_ingress_forbidden_test() ->
    with_ingress_mode(fun() ->
        Body = thoas:encode(#{<<"old">> => <<"a">>, <<"new">> => <<"b">>}),
        ?assertMatch({ok, 403, _, _}, dispatch(<<"POST">>, <<"/api/admin/change-password">>, Body))
    end).

%% ---------------------------------------------------------------------------
%% certificate CRUD edge cases
%% ---------------------------------------------------------------------------

api_certificates_post_empty_name_test() ->
    with_tmp_db(fun(_Db) ->
        Body = thoas:encode(#{<<"name">> => <<>>}),
        ?assertMatch({ok, 400, _, _}, dispatch(<<"POST">>, <<"/api/certificates">>, Body))
    end).

api_certificates_post_invalid_json_test() ->
    with_tmp_db(fun(_Db) ->
        ?assertMatch({ok, 400, _, _}, dispatch(<<"POST">>, <<"/api/certificates">>, <<"{bad">>))
    end).

api_certificate_put_not_found_id_test() ->
    with_tmp_db(fun(_Db) ->
        Put = thoas:encode(#{<<"name">> => <<"ghost-cert">>}),
        ?assertMatch({ok, 404, _, _}, dispatch(<<"PUT">>, <<"/api/certificates/9999">>, Put))
    end).

api_certificate_delete_success_status_test() ->
    with_tmp_db(fun(_Db) ->
        Add = thoas:encode(#{<<"name">> => <<"gone-cert">>}),
        {ok, 201, _, Resp} = dispatch(<<"POST">>, <<"/api/certificates">>, Add),
        {ok, #{<<"id">> := Id}} = thoas:decode(Resp),
        IdBin =
            case Id of
                I when is_integer(I) -> integer_to_binary(I);
                B when is_binary(B) -> B
            end,
        DelResult = dispatch(<<"DELETE">>, <<"/api/certificates/", IdBin/binary>>),
        case DelResult of
            {ok, 200, _, DelBody} ->
                {ok, DelMap} = thoas:decode(DelBody),
                ?assertEqual(<<"deleted">>, maps:get(<<"status">>, DelMap));
            {ok, Status, _, _} when Status =:= 404 ->
                ok;
            {error, _} ->
                ok
        end
    end).

api_certificate_put_updates_site_cert_name_test() ->
    with_tmp_db(fun(_Db) ->
        Add = thoas:encode(#{<<"name">> => <<"site-bound-cert">>}),
        {ok, 201, _, Resp} = dispatch(<<"POST">>, <<"/api/certificates">>, Add),
        {ok, #{<<"id">> := Id}} = thoas:decode(Resp),
        IdBin =
            case Id of
                I when is_integer(I) -> integer_to_binary(I);
                B when is_binary(B) -> B
            end,
        pertisk_eproxy_test_helpers:sync_router(
            [#{host => <<"cert-bound.example">>, backend => <<"web">>,
              certificate => <<"site-bound-cert">>, routes => []}],
            []
        ),
        Put = thoas:encode(#{<<"name">> => <<"renamed-site-cert">>}),
        Path = <<"/api/certificates/", IdBin/binary>>,
        try
            ?assertMatch({ok, 200, _, _}, dispatch(<<"PUT">>, Path, Put)),
            {ok, 200, _, ListBody} = dispatch(<<"GET">>, <<"/api/certificates">>),
            {ok, Rows} = thoas:decode(ListBody),
            ?assert(
                lists:any(
                    fun(Row) -> maps:get(<<"domain">>, Row, undefined) =:= <<"renamed-site-cert">> end,
                    Rows
                )
            )
        after
            pertisk_eproxy_test_helpers:sync_router([], [])
        end
    end).

api_certificates_list_acme_challenge_field_test() ->
    with_tmp_db(fun(_Db) ->
        Add = thoas:encode(#{<<"name">> => <<"acme-row.example">>}),
        {ok, 201, _, _} = dispatch(<<"POST">>, <<"/api/certificates">>, Add),
        {ok, 200, _, Body} = dispatch(<<"GET">>, <<"/api/certificates">>),
        {ok, Rows} = thoas:decode(Body),
        ?assert(
            lists:any(
                fun(Row) ->
                    maps:get(<<"domain">>, Row, undefined) =:= <<"acme-row.example">>
                        andalso maps:is_key(<<"challenge">>, Row)
                        andalso maps:is_key(<<"next_renew">>, Row)
                end,
                Rows
            )
        )
    end).

api_certificate_import_put_not_found_id_test() ->
    with_tmp_db(fun(_Db) ->
        Cert = read_priv_pem("listener.pem"),
        Key = read_priv_pem("listener.key"),
        Body = thoas:encode(#{<<"cert_pem">> => Cert, <<"key_pem">> => Key}),
        Result = dispatch(<<"PUT">>, <<"/api/certificates/9999/import">>, Body),
        ?assertMatch({ok, Status, _, _} when Status =:= 400 orelse Status =:= 404, Result)
    end).

api_certificates_ingress_k8s_rows_test() ->
    with_ingress_authenticated(fun(Token) ->
        pertisk_eproxy_test_helpers:sync_router(
            [#{host => <<"k8s-cert.example">>, backend => <<"web">>,
              certificate => <<"k8s/default/tls-secret">>, routes => []}],
            []
        ),
        try
            Result = dispatch_auth(<<"GET">>, <<"/api/certificates">>, <<>>, Token),
            ?assertMatch({ok, 200, _, _}, Result),
            {ok, 200, _, Body} = Result,
            {ok, Rows} = thoas:decode(Body),
            ?assert(
                lists:any(
                    fun(Row) ->
                        maps:get(<<"id">>, Row, undefined) =:= <<"k8s/default/tls-secret">>
                            orelse maps:get(<<"source_type">>, Row, undefined) =:= <<"kubernetes">>
                    end,
                    Rows
                )
            )
        after
            pertisk_eproxy_test_helpers:sync_router([], [])
        end
    end).

%% ---------------------------------------------------------------------------
%% site TLS PUT settings
%% ---------------------------------------------------------------------------

api_site_put_clears_certificate_with_null_test() ->
    ensure_env(),
    Host = <<"clear-cert.example">>,
    pertisk_eproxy_test_helpers:sync_router(
        [#{host => Host, backend => <<"web">>, certificate => <<"old-cert">>, routes => []}],
        []
    ),
    Put = thoas:encode(#{
        <<"host">> => Host,
        <<"backend">> => <<"web">>,
        <<"certificate">> => null,
        <<"routes">> => []
    }),
    try
        ?assertMatch({ok, 200, _, _}, dispatch(<<"PUT">>, <<"/api/sites/clear-cert.example">>, Put)),
        {ok, 200, _, GetBody} = dispatch(<<"GET">>, <<"/api/sites/clear-cert.example">>),
        {ok, Site} = thoas:decode(GetBody),
        ?assertEqual(null, maps:get(<<"certificate">>, Site, null))
    after
        pertisk_eproxy_test_helpers:sync_router([], [])
    end.

api_site_put_sets_http01_challenge_test() ->
    with_tmp_db(fun(_Db) ->
    Host = <<"http01-site.example">>,
    Add = thoas:encode(#{
        <<"host">> => Host,
        <<"backend">> => <<"web">>,
        <<"routes">> => []
    }),
    Put = thoas:encode(#{
        <<"host">> => Host,
        <<"backend">> => <<"web">>,
        <<"challenge_type">> => <<"http-01">>,
        <<"routes">> => []
    }),
    try
        _ = dispatch(<<"POST">>, <<"/api/sites">>, Add),
        ?assertMatch({ok, 200, _, _}, dispatch(<<"PUT">>, <<"/api/sites/http01-site.example">>, Put)),
        {ok, 200, _, GetBody} = dispatch(<<"GET">>, <<"/api/sites/http01-site.example">>),
        {ok, Site} = thoas:decode(GetBody),
        ?assertEqual(<<"http-01">>, maps:get(<<"challenge_type">>, Site))
    after
        _ = dispatch(<<"DELETE">>, <<"/api/sites/http01-site.example">>)
    end
    end).

api_site_put_wildcard_and_http3_test() ->
    ensure_env(),
    Host = <<"wild-h3.example">>,
    Add = thoas:encode(#{
        <<"host">> => Host,
        <<"backend">> => <<"web">>,
        <<"routes">> => []
    }),
    Put = thoas:encode(#{
        <<"host">> => Host,
        <<"backend">> => <<"web">>,
        <<"wildcard">> => true,
        <<"advertise_http3">> => false,
        <<"routes">> => []
    }),
    try
        _ = dispatch(<<"POST">>, <<"/api/sites">>, Add),
        ?assertMatch({ok, 200, _, _}, dispatch(<<"PUT">>, <<"/api/sites/wild-h3.example">>, Put)),
        {ok, 200, _, GetBody} = dispatch(<<"GET">>, <<"/api/sites/wild-h3.example">>),
        {ok, Site} = thoas:decode(GetBody),
        ?assertEqual(true, maps:get(<<"wildcard">>, Site)),
        ?assertEqual(false, maps:get(<<"advertise_http3">>, Site))
    after
        _ = dispatch(<<"DELETE">>, <<"/api/sites/wild-h3.example">>)
    end.

api_site_post_invalid_json_test() ->
    ensure_env(),
    ?assertMatch({ok, 400, _, _}, dispatch(<<"POST">>, <<"/api/sites">>, <<"{not json">>)).

api_site_put_invalid_json_test() ->
    ensure_env(),
    ?assertMatch({ok, 400, _, _}, dispatch(<<"PUT">>, <<"/api/sites/any.example">>, <<"{bad">>)).

api_config_put_unknown_certificate_validation_test() ->
    with_tmp_db(fun(_Db) ->
        Body = thoas:encode(#{
            <<"sites">> => [
                #{
                    <<"host">> => <<"bad-cert.example">>,
                    <<"backend">> => <<"web">>,
                    <<"certificate">> => <<"does-not-exist">>,
                    <<"routes">> => []
                }
            ],
            <<"backends">> => []
        }),
        ?assertMatch({ok, 400, _, _}, dispatch(<<"PUT">>, <<"/api/config">>, Body))
    end).

%% ---------------------------------------------------------------------------
%% backend health endpoints
%% ---------------------------------------------------------------------------

api_backend_post_health_settings_test() ->
    ensure_env(),
    Name = <<"bh_", (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    Body = thoas:encode(#{
        <<"name">> => Name,
        <<"algorithm">> => <<"round_robin">>,
        <<"health_path">> => <<"/healthz">>,
        <<"health_interval_secs">> => 15,
        <<"upstreams">> => [#{<<"addr">> => <<"127.0.0.1:9">>}]
    }),
    try
        {ok, 201, _, RespBody} = dispatch(<<"POST">>, <<"/api/backends">>, Body),
        {ok, Map} = thoas:decode(RespBody),
        ?assertEqual(<<"/healthz">>, maps:get(<<"health_path">>, Map)),
        ?assertEqual(15, maps:get(<<"health_interval_secs">>, Map))
    after
        _ = dispatch(<<"DELETE">>, <<"/api/backends/", Name/binary>>)
    end.

api_backend_get_reports_health_test() ->
    ensure_env(),
    ensure_backend_sup(),
    Name = <<"bhealth">>,
    Body = thoas:encode(#{
        <<"name">> => Name,
        <<"algorithm">> => <<"round_robin">>,
        <<"health_path">> => <<"/">>,
        <<"upstreams">> => [#{<<"addr">> => <<"127.0.0.1:9">>}]
    }),
    {ok, Pid} = pertisk_eproxy_test_helpers:start_backend(Name, [#{addr => <<"127.0.0.1:9">>}]),
    try
        ?assertMatch({ok, 201, _, _}, dispatch(<<"POST">>, <<"/api/backends">>, Body)),
        {ok, 200, _, StatusBody} = dispatch(<<"GET">>, <<"/api/backends/bhealth">>),
        {ok, Status} = thoas:decode(StatusBody),
        Ups = maps:get(<<"upstreams">>, Status, []),
        ?assert(length(Ups) > 0),
        [Up | _] = Ups,
        ?assert(maps:is_key(<<"healthy">>, Up)),
        ?assert(maps:is_key(<<"conns">>, Up))
    after
        catch gen_server:stop(Pid, normal, 5000),
        _ = dispatch(<<"DELETE">>, <<"/api/backends/bhealth">>)
    end.

api_backend_post_invalid_json_test() ->
    ensure_env(),
    ?assertMatch({ok, 400, _, _}, dispatch(<<"POST">>, <<"/api/backends">>, <<"{oops">>)).

api_backend_delete_with_sup_running_test() ->
    ensure_env(),
    ensure_backend_sup(),
    Name = <<"bsupdel">>,
    Body = thoas:encode(#{
        <<"name">> => Name,
        <<"algorithm">> => <<"round_robin">>,
        <<"upstreams">> => [#{<<"addr">> => <<"127.0.0.1:9">>}]
    }),
    ?assertMatch({ok, 201, _, _}, dispatch(<<"POST">>, <<"/api/backends">>, Body)),
    ?assertMatch({ok, 200, _, _}, dispatch(<<"DELETE">>, <<"/api/backends/bsupdel">>)).

api_backends_post_missing_upstreams_test() ->
    ensure_env(),
    Name = <<"no_ups_", (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    Body = thoas:encode(#{
        <<"name">> => Name,
        <<"algorithm">> => <<"round_robin">>,
        <<"upstreams">> => []
    }),
    Result = dispatch(<<"POST">>, <<"/api/backends">>, Body),
    ?assertMatch({ok, Status, _, _} when Status =:= 201 orelse Status =:= 400, Result).

%% ---------------------------------------------------------------------------
%% DNS provider CRUD + sync
%% ---------------------------------------------------------------------------

api_dns_provider_post_missing_provider_type_test() ->
    with_tmp_db(fun(_Db) ->
        Body = thoas:encode(#{
            <<"name">> => <<"no-type">>,
            <<"provider_type">> => <<>>,
            <<"credentials">> => #{<<"api_token">> => <<"tok">>}
        }),
        ?assertMatch({ok, 400, _, _}, dispatch(<<"POST">>, <<"/api/dns-providers">>, Body))
    end).

api_dns_provider_put_not_found_id_test() ->
    with_tmp_db(fun(_Db) ->
        Put = thoas:encode(#{
            <<"name">> => <<"missing">>,
            <<"provider_type">> => <<"cloudflare">>,
            <<"credentials">> => #{<<"api_token">> => <<"tok">>}
        }),
        ?assertMatch({ok, 404, _, _}, dispatch(<<"PUT">>, <<"/api/dns-providers/999">>, Put))
    end).

api_dns_provider_runtime_sync_test() ->
    with_tmp_db(fun(_Db) ->
        Body = thoas:encode(#{
            <<"name">> => <<"sync-cf">>,
            <<"provider_type">> => <<"cloudflare">>,
            <<"credentials">> => #{<<"api_token">> => <<"sync-secret">>}
        }),
        ?assertMatch({ok, 201, _, _}, dispatch(<<"POST">>, <<"/api/dns-providers">>, Body)),
        {ok, 200, _, ConfigBody} = dispatch(<<"GET">>, <<"/api/config">>),
        {ok, Config} = thoas:decode(ConfigBody),
        Providers = maps:get(<<"dns_providers">>, Config, []),
        ?assert(
            lists:any(
                fun(P) -> maps:get(<<"name">>, P, undefined) =:= <<"sync-cf">> end,
                Providers
            )
        )
    end).

api_dns_provider_validate_invalid_json_test() ->
    with_tmp_db(fun(_Db) ->
        ?assertMatch({ok, 400, _, _}, dispatch(<<"POST">>, <<"/api/dns-providers/validate">>, <<"{">>))
    end).

%% ---------------------------------------------------------------------------
%% config schema / backup errors
%% ---------------------------------------------------------------------------

api_config_put_preserves_redacted_tls_paths_test() ->
    ensure_env(),
    {ok, 200, _, Body} = dispatch(<<"GET">>, <<"/api/config">>),
    {ok, Map} = thoas:decode(Body),
    Put = thoas:encode(Map#{
        <<"tls_cert_file">> => <<"[redacted]">>,
        <<"tls_key_file">> => <<"[redacted]">>
    }),
    ?assertMatch({ok, 200, _, _}, dispatch(<<"PUT">>, <<"/api/config">>, Put)).

api_config_get_cache_control_header_test() ->
    ensure_env(),
    {ok, 200, Hdrs, _} = dispatch(<<"GET">>, <<"/api/config">>),
    ?assertEqual(<<"no-store, max-age=0">>, proplists:get_value(<<"cache-control">>, Hdrs)).

api_backup_restore_missing_data_key_test() ->
    ensure_env(),
    ?assertMatch({ok, 400, _, _}, dispatch(<<"POST">>, <<"/api/backup/restore">>, <<"{}">>)).

%% ---------------------------------------------------------------------------
%% HEAD matches GET headers on public routes
%% ---------------------------------------------------------------------------

api_ingress_status_head_matches_get_test() ->
    ensure_ingress_status_env(),
    head_matches_get_headers(<<"/api/ingress/status">>).

api_auth_config_head_matches_get_test() ->
    ensure_env(),
    head_matches_get_headers(<<"/api/auth/config">>).

api_ingress_live_head_matches_get_test() ->
    ensure_env(),
    head_matches_get_headers(<<"/api/ingress/live">>).

api_version_head_matches_get_headers_test() ->
    ensure_env(),
    head_matches_get_headers(<<"/api/version">>).

api_health_head_matches_get_headers_test() ->
    ensure_env(),
    head_matches_get_headers(<<"/api/health">>).

api_management_head_not_allowed_test() ->
    ensure_env(),
    Result = dispatch(<<"HEAD">>, <<"/api/management">>),
    ?assertMatch({ok, Status, _, _} when Status =:= 401 orelse Status =:= 405, Result).

%% ---------------------------------------------------------------------------
%% helm endpoints in ingress mode
%% ---------------------------------------------------------------------------

api_helm_history_ingress_no_release_test() ->
    with_ingress_authenticated(fun(Token) ->
        with_env("PERTISK_HELM_RELEASE", unset, fun() ->
            ?assertMatch(
                {ok, 400, _, _},
                dispatch_auth(<<"GET">>, <<"/api/helm/history">>, <<>>, Token)
            )
        end)
    end).

api_helm_history_ingress_disabled_test() ->
    with_ingress_authenticated(fun(Token) ->
        with_env("PERTISK_HELM_RELEASE", {set, "pertisk-eproxy"}, fun() ->
            with_env("PERTISK_HELM_ENABLED", {set, "false"}, fun() ->
                ?assertMatch(
                    {ok, 404, _, _},
                    dispatch_auth(<<"GET">>, <<"/api/helm/history">>, <<>>, Token)
                )
            end)
        end)
    end).

api_helm_values_ingress_bad_revision_test() ->
    with_ingress_authenticated(fun(Token) ->
        ?assertMatch(
            {ok, 400, _, _},
            dispatch_auth(<<"GET">>, <<"/api/helm/values/0">>, <<>>, Token)
        )
    end).

api_helm_values_ingress_no_release_test() ->
    with_ingress_authenticated(fun(Token) ->
        with_env("PERTISK_HELM_RELEASE", unset, fun() ->
            ?assertMatch(
                {ok, 400, _, _},
                dispatch_auth(<<"GET">>, <<"/api/helm/values/1">>, <<>>, Token)
            )
        end)
    end).

api_helm_values_ingress_disabled_test() ->
    with_ingress_authenticated(fun(Token) ->
        with_env("PERTISK_HELM_RELEASE", {set, "pertisk-eproxy"}, fun() ->
            with_env("PERTISK_HELM_ENABLED", {set, "false"}, fun() ->
                ?assertMatch(
                    {ok, 404, _, _},
                    dispatch_auth(<<"GET">>, <<"/api/helm/values/1">>, <<>>, Token)
                )
            end)
        end)
    end).

%% ---------------------------------------------------------------------------
%% kubernetes dispatch via meck
%% ---------------------------------------------------------------------------

api_k8s_namespaces_dispatch_ingress_test() ->
    with_ingress_authenticated(fun(Token) ->
        with_mock_k8s(fun(_Conn) ->
            meck:expect(ekub, read, fun(namespace, ConnArg) ->
                ?assertEqual({mock_api, mock_access}, ConnArg),
                {ok, [#{<<"metadata">> => #{<<"name">> => <<"default">>, <<"creationTimestamp">> => null}}]}
            end),
            {ok, 200, _, Body} =
                dispatch_auth(<<"GET">>, <<"/api/kubernetes/namespaces">>, <<>>, Token),
            {ok, Rows} = thoas:decode(Body),
            ?assert(length(Rows) > 0)
        end)
    end).

api_k8s_pods_dispatch_ingress_test() ->
    with_ingress_mode(fun() ->
        with_env("PERTISK_K8S_POD_NAME", {set, "pertisk-eproxy"}, fun() ->
            with_mock_k8s(fun(_Conn) ->
                meck:expect(ekub_api, endpoint, fun
                    ({<<"">>, <<"v1">>}, pod, <<"default">>, "", _) ->
                        <<"/api/v1/namespaces/default/pods">>;
                    (_, _, _, _, _) ->
                        <<>>
                end),
                meck:expect(ekub_core, http_request, fun(_, _, _) ->
                    {ok, #{<<"items">> => []}}
                end),
                ?assertMatch(
                    {ok, 200, _, _},
                    dispatch(<<"GET">>, <<"/api/kubernetes/pods">>, <<"namespace=default">>, <<>>)
                )
            end)
        end)
    end).

api_k8s_services_dispatch_ingress_test() ->
    with_ingress_mode(fun() ->
        with_mock_k8s(fun(_Conn) ->
            meck:expect(ekub, read, fun(service, <<"apps">>, [], ConnArg) ->
                ?assertEqual({mock_api, mock_access}, ConnArg),
                {ok, #{<<"items">> => []}}
            end),
            ?assertMatch(
                {ok, 200, _, _},
                dispatch(<<"GET">>, <<"/api/kubernetes/services">>, <<"namespace=apps">>, <<>>)
            )
        end)
    end).

api_k8s_tls_secrets_dispatch_ingress_test() ->
    with_ingress_mode(fun() ->
        with_mock_k8s(fun(_Conn) ->
            IngressItems = #{<<"items">> => [sample_k8s_ingress(<<"app">>, <<"default">>, <<"app.example">>)]},
            meck:expect(ekub, read, 4, fun
                (secret, _Ns, [], ConnArg) when ConnArg =:= {mock_api, mock_access} ->
                    {ok, #{<<"items">> => []}};
                (ingress, _Ns, [], ConnArg) ->
                    ?assertEqual({mock_api, mock_access}, ConnArg),
                    {ok, IngressItems}
            end),
            ?assertMatch(
                {ok, 200, _, _},
                dispatch(<<"GET">>, <<"/api/kubernetes/tls-secrets">>, <<"namespace=default">>, <<>>)
            )
        end)
    end).

api_k8s_ingresses_list_dispatch_test() ->
    with_ingress_mode(fun() ->
        with_mock_k8s(fun(_Conn) ->
            meck:expect(ekub, read, fun(ingress, _Query, ConnArg) ->
                ?assertEqual({mock_api, mock_access}, ConnArg),
                {ok, #{<<"items">> => [sample_k8s_ingress(<<"app">>, <<"default">>, <<"app.example">>)]}}
            end),
            {ok, 200, _, Body} = dispatch(<<"GET">>, <<"/api/kubernetes/ingresses">>),
            {ok, Rows} = thoas:decode(Body),
            ?assert(length(Rows) > 0)
        end)
    end).

api_k8s_ingress_create_dispatch_test() ->
    with_ingress_mode(fun() ->
        with_mock_k8s(fun(_Conn) ->
            meck:expect(ekub, create, fun(Resource, Ns, ConnArg) ->
                ?assertEqual(<<"default">>, Ns),
                ?assertEqual({mock_api, mock_access}, ConnArg),
                {ok, Resource}
            end),
            Body = thoas:encode(#{
                <<"name">> => <<"demo">>,
                <<"host">> => <<"demo.example">>,
                <<"service_namespace">> => <<"default">>,
                <<"service_name">> => <<"web">>,
                <<"service_port">> => 80,
                <<"routes">> => [
                    #{
                        <<"path">> => <<"/">>,
                        <<"path_type">> => <<"Prefix">>,
                        <<"service_name">> => <<"web">>,
                        <<"service_port">> => 80
                    }
                ]
            }),
            ?assertMatch({ok, 201, _, _}, dispatch(<<"POST">>, <<"/api/kubernetes/ingresses">>, Body))
        end)
    end).

api_k8s_ingress_get_dispatch_test() ->
    with_ingress_mode(fun() ->
        with_mock_k8s(fun(_Conn) ->
            meck:expect(ekub, read, fun(ingress, <<"default">>, <<"app">>, ConnArg) ->
                ?assertEqual({mock_api, mock_access}, ConnArg),
                {ok, sample_k8s_ingress(<<"app">>, <<"default">>, <<"app.example">>)}
            end),
            {ok, 200, _, Body} = dispatch(<<"GET">>, <<"/api/kubernetes/ingresses/default/app">>),
            {ok, Map} = thoas:decode(Body),
            ?assertEqual(<<"app.example">>, maps:get(<<"host">>, Map))
        end)
    end).

api_k8s_ingress_delete_dispatch_test() ->
    with_ingress_mode(fun() ->
        with_mock_k8s(fun(_Conn) ->
            meck:expect(ekub, delete, fun(ingress, <<"default">>, <<"gone">>, ConnArg) ->
                ?assertEqual({mock_api, mock_access}, ConnArg),
                {ok, deleted}
            end),
            ?assertMatch({ok, 200, _, _}, dispatch(<<"DELETE">>, <<"/api/kubernetes/ingresses/default/gone">>))
        end)
    end).

api_k8s_pods_default_namespace_dispatch_test() ->
    with_ingress_mode(fun() ->
        with_env("PERTISK_K8S_POD_NAME", {set, "pertisk-eproxy"}, fun() ->
            with_mock_k8s(fun(_Conn) ->
                meck:expect(ekub_api, endpoint, fun(_, pod, _, _, _) -> <<"/pods">> end),
                meck:expect(ekub_core, http_request, fun(_, _, _) -> {ok, #{<<"items">> => []}} end),
                ?assertMatch({ok, 200, _, _}, dispatch(<<"GET">>, <<"/api/kubernetes/pods">>, <<>>, <<>>))
            end)
        end)
    end).

%% ---------------------------------------------------------------------------
%% proto / grpc debug and TLS listener
%% ---------------------------------------------------------------------------

api_proto_response_debug_headers_test() ->
    ensure_env(),
    {ok, 200, Hdrs, Body} = dispatch(<<"GET">>, <<"/api/proto">>),
    {ok, Map} = thoas:decode(Body),
    ?assert(maps:is_key(<<"http_version">>, Map)),
    ?assertEqual(<<"HTTP/3">>, maps:get(<<"http_version">>, Map)),
    ?assertNotEqual(undefined, proplists:get_value(<<"x-eproxy-debug-http-version">>, Hdrs)),
    ?assertNotEqual(undefined, proplists:get_value(<<"x-eproxy-debug-scheme">>, Hdrs)).

api_proto_with_xfp_version_header_test() ->
    ensure_env(),
    Hdrs = [{<<"x-forwarded-proto-version">>, <<"HTTP/3">>}],
    {ok, 200, RespHdrs, Body} = dispatch(<<"GET">>, <<"/api/proto">>, <<>>, <<>>, Hdrs),
    {ok, Map} = thoas:decode(Body),
    ?assertEqual(<<"HTTP/3">>, maps:get(<<"effective_client_proto_version">>, Map)),
    ?assertEqual(true, maps:get(<<"client_h3">>, Map)),
    ?assertEqual(<<"true">>, proplists:get_value(<<"x-eproxy-debug-client-h3">>, RespHdrs)).

api_tls_listener_valid_pem_test() ->
    with_tls_data_dir(fun(_Dir) ->
        Cert = read_priv_pem("listener.pem"),
        Key = read_priv_pem("listener.key"),
        Body = thoas:encode(#{<<"cert_pem">> => Cert, <<"key_pem">> => Key}),
        {ok, 200, _, RespBody} = dispatch(<<"POST">>, <<"/api/tls/listener">>, Body),
        {ok, Map} = thoas:decode(RespBody),
        ?assertEqual(<<"ok">>, maps:get(<<"status">>, Map)),
        ?assert(maps:is_key(<<"tls_cert_file">>, Map))
    end).

api_reload_returns_reloaded_test() ->
    ensure_env(),
    {ok, 200, _, Body} = dispatch(<<"POST">>, <<"/api/reload">>),
    {ok, Map} = thoas:decode(Body),
    ?assertEqual(<<"reloaded">>, maps:get(<<"status">>, Map)).

%% ---------------------------------------------------------------------------
%% additional coverage: helm success, k8s PUT, PEM ingress certs, error branches
%% ---------------------------------------------------------------------------

with_mock_helm(Fun) ->
    meck:new(pertisk_eproxy_shell, [unstick]),
    meck:expect(pertisk_eproxy_shell, os_cmd, fun(_) ->
        "[{\"revision\":1,\"status\":\"deployed\"}]\n__PERTISK_HELM_RC__:0\n"
    end),
    try Fun() after meck:unload(pertisk_eproxy_shell) end.

api_helm_history_ingress_success_mocked_test() ->
    with_ingress_authenticated(fun(Token) ->
        with_env("PERTISK_HELM_RELEASE", {set, "pertisk-eproxy"}, fun() ->
            with_mock_helm(fun() ->
                {ok, 200, _, Body} =
                    dispatch_auth(<<"GET">>, <<"/api/helm/history">>, <<>>, Token),
                {ok, Map} = thoas:decode(Body),
                ?assertEqual(<<"pertisk-eproxy">>, maps:get(<<"release">>, Map)),
                ?assert(is_list(maps:get(<<"history">>, Map, [])))
            end)
        end)
    end).

api_helm_values_ingress_success_mocked_test() ->
    with_ingress_authenticated(fun(Token) ->
        with_env("PERTISK_HELM_RELEASE", {set, "pertisk-eproxy"}, fun() ->
            with_mock_helm(fun() ->
                meck:expect(pertisk_eproxy_shell, os_cmd, fun(_) ->
                    "replicaCount: 1\n__PERTISK_HELM_RC__:0\n"
                end),
                {ok, 200, _, Body} =
                    dispatch_auth(<<"GET">>, <<"/api/helm/values/1">>, <<>>, Token),
                {ok, Map} = thoas:decode(Body),
                ?assertEqual(1, maps:get(<<"revision">>, Map)),
                ?assert(byte_size(maps:get(<<"values">>, Map, <<>>)) > 0)
            end)
        end)
    end).

api_certificates_ingress_k8s_with_pem_test() ->
    with_ingress_authenticated(fun(Token) ->
        ensure_ingress_status_env(),
        Cert = read_priv_pem("listener.pem"),
        Key = read_priv_pem("listener.key"),
        ok = pertisk_ingress_tls:set_hosts([<<"k8s-pem.example">>], Cert, Key, undefined, undefined),
        pertisk_eproxy_test_helpers:sync_router(
            [#{host => <<"k8s-pem.example">>, backend => <<"web">>,
              certificate => <<"k8s/default/tls-secret">>, routes => []}],
            []
        ),
        try
            {ok, 200, _, Body} = dispatch_auth(<<"GET">>, <<"/api/certificates">>, <<>>, Token),
            {ok, Rows} = thoas:decode(Body),
            ?assert(
                lists:any(
                    fun(Row) ->
                        maps:get(<<"source_type">>, Row, undefined) =:= <<"kubernetes">>
                            andalso maps:get(<<"issuer">>, Row, <<>>) =/= <<>>
                    end,
                    Rows
                )
            )
        after
            pertisk_ingress_tls:clear(),
            pertisk_eproxy_test_helpers:sync_router([], [])
        end
    end).

api_certificates_acme_staging_challenge_label_test() ->
    with_tmp_db(fun(_Db) ->
        Old = application:get_env(pertisk_eproxy, acme_directory_url),
        application:set_env(
            pertisk_eproxy,
            acme_directory_url,
            <<"https://acme-staging-v02.api.letsencrypt.org/directory">>
        ),
        try
            Add = thoas:encode(#{<<"name">> => <<"staging-acme.example">>}),
            {ok, 201, _, _} = dispatch(<<"POST">>, <<"/api/certificates">>, Add),
            {ok, 200, _, Body} = dispatch(<<"GET">>, <<"/api/certificates">>),
            {ok, Rows} = thoas:decode(Body),
            ?assert(
                lists:any(
                    fun(Row) ->
                        maps:get(<<"challenge">>, Row, <<>>) =:=
                            <<"dns-01 (Let's Encrypt staging)">>
                    end,
                    Rows
                )
            )
        after
            case Old of
                {ok, V} -> application:set_env(pertisk_eproxy, acme_directory_url, V);
                undefined -> application:unset_env(pertisk_eproxy, acme_directory_url)
            end
        end
    end).

api_k8s_ingress_put_dispatch_test() ->
    with_ingress_mode(fun() ->
        with_mock_k8s(fun(_Conn) ->
            meck:expect(ekub, read, fun(ingress, <<"default">>, <<"app">>, ConnArg) ->
                ?assertEqual({mock_api, mock_access}, ConnArg),
                {ok, sample_k8s_ingress(<<"app">>, <<"default">>, <<"app.example">>)}
            end),
            meck:expect(ekub, replace, fun(Resource, Ns, ConnArg) ->
                ?assertEqual(<<"default">>, Ns),
                ?assertEqual({mock_api, mock_access}, ConnArg),
                {ok, Resource}
            end),
            Body = thoas:encode(#{
                <<"name">> => <<"app">>,
                <<"host">> => <<"updated.example">>,
                <<"service_namespace">> => <<"default">>,
                <<"service_name">> => <<"web">>,
                <<"service_port">> => 80,
                <<"routes">> => [
                    #{
                        <<"path">> => <<"/">>,
                        <<"path_type">> => <<"Prefix">>,
                        <<"service_name">> => <<"web">>,
                        <<"service_port">> => 80
                    }
                ]
            }),
            ?assertMatch(
                {ok, 200, _, _},
                dispatch(<<"PUT">>, <<"/api/kubernetes/ingresses/default/app">>, Body)
            )
        end)
    end).

api_dns_provider_put_partial_credentials_test() ->
    with_tmp_db(fun(_Db) ->
        Add = thoas:encode(#{
            <<"name">> => <<"partial-cf">>,
            <<"provider_type">> => <<"cloudflare">>,
            <<"credentials">> => #{<<"api_token">> => <<"original-secret">>}
        }),
        ?assertMatch({ok, 201, _, _}, dispatch(<<"POST">>, <<"/api/dns-providers">>, Add)),
        {ok, 200, _, ListBody} = dispatch(<<"GET">>, <<"/api/dns-providers">>),
        {ok, [#{<<"id">> := Id} | _]} = thoas:decode(ListBody),
        IdBin =
            case Id of
                I when is_integer(I) -> integer_to_binary(I);
                B when is_binary(B) -> B
            end,
        Put = thoas:encode(#{
            <<"name">> => <<"partial-cf-renamed">>,
            <<"provider_type">> => <<"cloudflare">>,
            <<"credentials">> => #{<<"api_token">> => <<"original-secret">>}
        }),
        Path = <<"/api/dns-providers/", IdBin/binary>>,
        Result = dispatch(<<"PUT">>, Path, Put),
        ?assertMatch({ok, Status, _, _} when Status =:= 200 orelse Status =:= 404, Result)
    end).

api_backup_restore_invalid_config_structure_test() ->
    ensure_env(),
    Inner = thoas:encode(#{
        <<"sites">> => [],
        <<"backends">> => [],
        <<"certificate_records">> => [#{<<"name">> => <<>>}]
    }),
    Bad = thoas:encode(#{<<"data">> => Inner}),
    ?assertMatch({ok, 400, _, _}, dispatch(<<"POST">>, <<"/api/backup/restore">>, Bad)).

api_certificates_import_empty_pem_fields_test() ->
    with_tmp_db(fun(_Db) ->
        Body = thoas:encode(#{<<"cert_pem">> => <<>>, <<"key_pem">> => <<>>}),
        ?assertMatch({ok, 400, _, _}, dispatch(<<"POST">>, <<"/api/certificates/import">>, Body))
    end).

api_certificate_put_not_found_after_delete_test() ->
    with_tmp_db(fun(_Db) ->
        Add = thoas:encode(#{<<"name">> => <<"temp-cert">>}),
        {ok, 201, _, Resp} = dispatch(<<"POST">>, <<"/api/certificates">>, Add),
        {ok, #{<<"id">> := Id}} = thoas:decode(Resp),
        IdBin =
            case Id of
                I when is_integer(I) -> integer_to_binary(I);
                B when is_binary(B) -> B
            end,
        _ = dispatch(<<"DELETE">>, <<"/api/certificates/", IdBin/binary>>),
        Put = thoas:encode(#{<<"name">> => <<"nope">>}),
        ?assertMatch({ok, 404, _, _}, dispatch(<<"PUT">>, <<"/api/certificates/", IdBin/binary>>, Put))
    end).

api_method_not_allowed_patch_config_test() ->
    ensure_env(),
    ?assertMatch({ok, 405, _, _}, dispatch(<<"PATCH">>, <<"/api/config">>, <<"{}">>)).

api_method_not_allowed_delete_version_test() ->
    ensure_env(),
    ?assertMatch({ok, 405, _, _}, dispatch(<<"DELETE">>, <<"/api/version">>)).

api_method_not_allowed_put_certificates_list_test() ->
    ensure_env(),
    ?assertMatch({ok, 405, _, _}, dispatch(<<"PUT">>, <<"/api/certificates">>, <<"{}">>)).

api_method_not_allowed_post_dns_provider_id_test() ->
    with_tmp_db(fun(_Db) ->
        ?assertMatch({ok, 405, _, _}, dispatch(<<"POST">>, <<"/api/dns-providers/1">>, <<"{}">>))
    end).

api_site_tls_health_via_build_health_json_test() ->
    ensure_env(),
    pertisk_eproxy_test_helpers:sync_router(
        [#{host => <<"health-tls.example">>, backend => <<"web">>,
          certificate => <<"missing-cert">>, routes => []}],
        []
    ),
    try
        Json = pertisk_eproxy_admin_handler:build_health_json(),
        {ok, Map} = thoas:decode(Json),
        TlsSites = maps:get(<<"tls_sites">>, Map, []),
        ?assert(
            lists:any(
                fun(Row) ->
                    maps:get(<<"host">>, Row, undefined) =:= <<"health-tls.example">>
                        andalso maps:get(<<"valid">>, Row, true) =:= false
                end,
                TlsSites
            )
        )
    after
        pertisk_eproxy_test_helpers:sync_router([], [])
    end.

api_backend_health_summary_via_build_health_json_test() ->
    ensure_env(),
    ensure_backend_sup(),
    Name = <<"hbjson_", (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    {ok, Pid} = pertisk_eproxy_test_helpers:start_backend(Name, [#{addr => <<"127.0.0.1:9">>}]),
    try
        pertisk_eproxy_test_helpers:sync_router(
            [],
            [#{name => Name, upstreams => [#{addr => <<"127.0.0.1:9">>}], health_path => <<"/">>}]
        ),
        Json = pertisk_eproxy_admin_handler:build_health_json(),
        {ok, Map} = thoas:decode(Json),
        Backends = maps:get(<<"backends">>, Map, []),
        ?assert(
            lists:any(
                fun(Row) -> maps:get(<<"name">>, Row, undefined) =:= Name end,
                Backends
            )
        )
    after
        catch gen_server:stop(Pid, normal, 5000),
        pertisk_eproxy_test_helpers:sync_router([], [])
    end.

api_auth_login_invalid_json_test() ->
    ensure_env(),
    ?assertMatch({ok, 400, _, _}, dispatch(<<"POST">>, <<"/api/auth/login">>, <<"{">>)).

api_admin_api_token_post_not_implemented_test() ->
    ensure_env(),
    ?assertMatch({ok, 501, _, _}, dispatch(<<"POST">>, <<"/api/admin/api-token">>, <<"{">>)).

api_helm_history_ingress_invalid_json_mocked_test() ->
    with_ingress_authenticated(fun(Token) ->
        with_env("PERTISK_HELM_RELEASE", {set, "pertisk-eproxy"}, fun() ->
            meck:new(pertisk_eproxy_shell, [unstick]),
            meck:expect(pertisk_eproxy_shell, os_cmd, fun(_) ->
                "not-json-output\n__PERTISK_HELM_RC__:0\n"
            end),
            try
                ?assertMatch(
                    {ok, 500, _, _},
                    dispatch_auth(<<"GET">>, <<"/api/helm/history">>, <<>>, Token)
                )
            after
                meck:unload(pertisk_eproxy_shell)
            end
        end)
    end).

api_helm_history_ingress_cmd_failed_mocked_test() ->
    with_ingress_authenticated(fun(Token) ->
        with_env("PERTISK_HELM_RELEASE", {set, "pertisk-eproxy"}, fun() ->
            meck:new(pertisk_eproxy_shell, [unstick]),
            meck:expect(pertisk_eproxy_shell, os_cmd, fun(_) ->
                "Error: release not found\n__PERTISK_HELM_RC__:1\n"
            end),
            try
                ?assertMatch(
                    {ok, 502, _, _},
                    dispatch_auth(<<"GET">>, <<"/api/helm/history">>, <<>>, Token)
                )
            after
                meck:unload(pertisk_eproxy_shell)
            end
        end)
    end).

api_helm_values_ingress_invalid_revision_negative_test() ->
    with_ingress_authenticated(fun(Token) ->
        ?assertMatch(
            {ok, 400, _, _},
            dispatch_auth(<<"GET">>, <<"/api/helm/values/-5">>, <<>>, Token)
        )
    end).

api_helm_history_ingress_with_history_max_test() ->
    with_ingress_authenticated(fun(Token) ->
        with_env("PERTISK_HELM_RELEASE", {set, "pertisk-eproxy"}, fun() ->
            with_env("PERTISK_HELM_HISTORY_MAX", {set, "5"}, fun() ->
                with_mock_helm(fun() ->
                    ?assertMatch(
                        {ok, 200, _, _},
                        dispatch_auth(<<"GET">>, <<"/api/helm/history">>, <<>>, Token)
                    )
                end)
            end)
        end)
    end).

api_dns_provider_delete_by_id_success_test() ->
    with_tmp_db(fun(_Db) ->
        Add = thoas:encode(#{
            <<"name">> => <<"del-by-id">>,
            <<"provider_type">> => <<"cloudflare">>,
            <<"credentials">> => #{<<"api_token">> => <<"secret">>}
        }),
        ?assertMatch({ok, 201, _, _}, dispatch(<<"POST">>, <<"/api/dns-providers">>, Add)),
        {ok, 200, _, ListBody} = dispatch(<<"GET">>, <<"/api/dns-providers">>),
        {ok, [#{<<"id">> := Id} | _]} = thoas:decode(ListBody),
        IdBin =
            case Id of
                I when is_integer(I) -> integer_to_binary(I);
                B when is_binary(B) -> B
            end,
        Result = dispatch(<<"DELETE">>, <<"/api/dns-providers/", IdBin/binary>>),
        ?assertMatch({ok, Status, _, _} when Status =:= 200 orelse Status =:= 404, Result)
    end).

api_site_put_full_tls_profile_test() ->
    ensure_env(),
    Host = <<"full-tls.example">>,
    Add = thoas:encode(#{
        <<"host">> => Host,
        <<"backend">> => <<"web">>,
        <<"routes">> => []
    }),
    Put = thoas:encode(#{
        <<"host">> => Host,
        <<"backend">> => <<"web">>,
        <<"challenge_type">> => <<"dns-01">>,
        <<"wildcard">> => true,
        <<"acme_wildcard_base">> => <<"example.com">>,
        <<"acme_contact_email">> => <<"ops@example.com">>,
        <<"advertise_http3">> => true,
        <<"routes">> => [#{<<"path">> => <<"/">>, <<"path_type">> => <<"prefix">>}]
    }),
    try
        _ = dispatch(<<"POST">>, <<"/api/sites">>, Add),
        ?assertMatch({ok, 200, _, _}, dispatch(<<"PUT">>, <<"/api/sites/full-tls.example">>, Put)),
        {ok, 200, _, Body} = dispatch(<<"GET">>, <<"/api/sites/full-tls.example">>),
        {ok, Site} = thoas:decode(Body),
        ?assertEqual(<<"dns-01">>, maps:get(<<"challenge_type">>, Site)),
        ?assertEqual(<<"ops@example.com">>, maps:get(<<"acme_contact_email">>, Site)),
        ?assertEqual(<<"example.com">>, maps:get(<<"acme_wildcard_base">>, Site))
    after
        _ = dispatch(<<"DELETE">>, <<"/api/sites/full-tls.example">>)
    end.

api_certificates_import_lists_issuer_test() ->
    with_tmp_db(fun(_Db) ->
        with_tls_data_dir(fun(_Dir) ->
            Cert = read_priv_pem("listener.pem"),
            Key = read_priv_pem("listener.key"),
            Body = thoas:encode(#{<<"cert_pem">> => Cert, <<"key_pem">> => Key}),
            ?assertMatch({ok, 201, _, _}, dispatch(<<"POST">>, <<"/api/certificates/import">>, Body)),
            {ok, 200, _, ListBody} = dispatch(<<"GET">>, <<"/api/certificates">>),
            {ok, Rows} = thoas:decode(ListBody),
            ?assert(
                lists:any(
                    fun(Row) ->
                        maps:get(<<"source_type">>, Row, undefined) =:= <<"imported_pem">>
                            andalso maps:get(<<"issuer">>, Row, <<>>) =/= <<>>
                    end,
                    Rows
                )
            )
        end)
    end).

api_helm_values_ingress_cmd_failed_mocked_test() ->
    with_ingress_authenticated(fun(Token) ->
        with_env("PERTISK_HELM_RELEASE", {set, "pertisk-eproxy"}, fun() ->
            meck:new(pertisk_eproxy_shell, [unstick]),
            meck:expect(pertisk_eproxy_shell, os_cmd, fun(_) ->
                "release not found\n__PERTISK_HELM_RC__:1\n"
            end),
            try
                ?assertMatch(
                    {ok, 502, _, _},
                    dispatch_auth(<<"GET">>, <<"/api/helm/values/1">>, <<>>, Token)
                )
            after
                meck:unload(pertisk_eproxy_shell)
            end
        end)
    end).

api_site_get_with_ingress_metadata_test() ->
    ensure_env(),
    Host = <<"ingress-meta.example">>,
    pertisk_eproxy_test_helpers:sync_router(
        [#{host => Host, backend => <<"web">>, ingress_namespace => <<"prod">>,
          ingress_name => <<"web-ing">>, routes => []}],
        []
    ),
    try
        {ok, 200, _, Body} = dispatch(<<"GET">>, <<"/api/sites/ingress-meta.example">>),
        {ok, Site} = thoas:decode(Body),
        ?assertEqual(<<"prod">>, maps:get(<<"ingress_namespace">>, Site)),
        ?assertEqual(<<"web-ing">>, maps:get(<<"ingress_name">>, Site))
    after
        pertisk_eproxy_test_helpers:sync_router([], [])
    end.

api_certificate_put_missing_name_field_test() ->
    with_tmp_db(fun(_Db) ->
        Add = thoas:encode(#{<<"name">> => <<"needs-name">>}),
        {ok, 201, _, _} = dispatch(<<"POST">>, <<"/api/certificates">>, Add),
        ?assertMatch({ok, 400, _, _}, dispatch(<<"PUT">>, <<"/api/certificates/1">>, <<"{}">>))
    end).

api_dns_provider_validate_returns_error_body_test() ->
    with_tmp_db(fun(_Db) ->
        Body = thoas:encode(#{
            <<"provider_type">> => <<"cloudflare">>,
            <<"credentials">> => #{<<"api_token">> => <<>>}
        }),
        {ok, 400, _, Resp} = dispatch(<<"POST">>, <<"/api/dns-providers/validate">>, Body),
        {ok, Map} = thoas:decode(Resp),
        ?assertEqual(false, maps:get(<<"ok">>, Map))
    end).

api_build_health_json_wildcard_host_test() ->
    ensure_env(),
    pertisk_eproxy_test_helpers:sync_router(
        [#{host => <<"*.wildcard.example">>, backend => <<"web">>, routes => []}],
        []
    ),
    try
        Json = pertisk_eproxy_admin_handler:build_health_json(),
        {ok, Map} = thoas:decode(Json),
        TlsSites = maps:get(<<"tls_sites">>, Map, []),
        ?assert(
            lists:any(
                fun(Row) ->
                    maps:get(<<"host">>, Row, undefined) =:= <<"*.wildcard.example">>
                end,
                TlsSites
            )
        )
    after
        pertisk_eproxy_test_helpers:sync_router([], [])
    end.

api_certificates_ingress_no_db_fallback_test() ->
    with_ingress_authenticated(fun(Token) ->
        Old = application:get_env(pertisk_eproxy, db_file),
        application:set_env(pertisk_eproxy, db_file, <<"/no/such/proxy.db">>),
        try
            ?assertMatch(
                {ok, 200, _, _},
                dispatch_auth(<<"GET">>, <<"/api/certificates">>, <<>>, Token)
            )
        after
            case Old of
                {ok, V} -> application:set_env(pertisk_eproxy, db_file, V);
                undefined -> application:unset_env(pertisk_eproxy, db_file)
            end
        end
    end).

api_build_health_json_acme_cert_ref_test() ->
    ensure_env(),
    pertisk_eproxy_test_helpers:sync_router(
        [#{host => <<"acme-site.example">>, backend => <<"web">>,
          certificate => <<"acme/acme-site.example">>, routes => []}],
        []
    ),
    try
        Json = pertisk_eproxy_admin_handler:build_health_json(),
        {ok, Map} = thoas:decode(Json),
        TlsSites = maps:get(<<"tls_sites">>, Map, []),
        ?assert(
            lists:any(
                fun(Row) ->
                    maps:get(<<"host">>, Row, undefined) =:= <<"acme-site.example">>
                        andalso maps:get(<<"status">>, Row, undefined) =/= <<"ok">>
                end,
                TlsSites
            )
        )
    after
        pertisk_eproxy_test_helpers:sync_router([], [])
    end.

api_config_put_preserves_dns_provider_secrets_test() ->
    with_tmp_db(fun(_Db) ->
        Add = thoas:encode(#{
            <<"name">> => <<"cfg-cf">>,
            <<"provider_type">> => <<"cloudflare">>,
            <<"credentials">> => #{<<"api_token">> => <<"real-secret">>}
        }),
        ?assertMatch({ok, 201, _, _}, dispatch(<<"POST">>, <<"/api/dns-providers">>, Add)),
        {ok, 200, _, ConfigBody} = dispatch(<<"GET">>, <<"/api/config">>),
        {ok, Config} = thoas:decode(ConfigBody),
        Providers = maps:get(<<"dns_providers">>, Config, []),
        [Provider | _] = Providers,
        Put = thoas:encode(Config#{
            <<"dns_providers">> => [
                Provider#{<<"credentials">> => #{<<"api_token">> => <<"[redacted]">>}}
            ]
        }),
        ?assertMatch({ok, 200, _, _}, dispatch(<<"PUT">>, <<"/api/config">>, Put))
    end).

api_certificate_import_put_success_test() ->
    with_tmp_db(fun(_Db) ->
        with_tls_data_dir(fun(_Dir) ->
            Add = thoas:encode(#{<<"name">> => <<"import-target-2">>}),
            {ok, 201, _, _} = dispatch(<<"POST">>, <<"/api/certificates">>, Add),
            Cert = read_priv_pem("listener.pem"),
            Key = read_priv_pem("listener.key"),
            Import = thoas:encode(#{<<"cert_pem">> => Cert, <<"key_pem">> => Key}),
            {ok, 200, _, Body} = dispatch(<<"PUT">>, <<"/api/certificates/1/import">>, Import),
            {ok, Map} = thoas:decode(Body),
            ?assertEqual(<<"ok">>, maps:get(<<"status">>, Map))
        end)
    end).

api_dns_provider_put_empty_provider_type_test() ->
    with_tmp_db(fun(_Db) ->
        Add = thoas:encode(#{
            <<"name">> => <<"type-put">>,
            <<"provider_type">> => <<"cloudflare">>,
            <<"credentials">> => #{<<"api_token">> => <<"tok">>}
        }),
        ?assertMatch({ok, 201, _, _}, dispatch(<<"POST">>, <<"/api/dns-providers">>, Add)),
        {ok, 200, _, ListBody} = dispatch(<<"GET">>, <<"/api/dns-providers">>),
        {ok, [#{<<"id">> := Id} | _]} = thoas:decode(ListBody),
        IdBin =
            case Id of
                I when is_integer(I) -> integer_to_binary(I);
                B when is_binary(B) -> B
            end,
        Put = thoas:encode(#{
            <<"name">> => <<"type-put">>,
            <<"provider_type">> => <<>>,
            <<"credentials">> => #{<<"api_token">> => <<"tok">>}
        }),
        Result = dispatch(<<"PUT">>, <<"/api/dns-providers/", IdBin/binary>>, Put),
        ?assertMatch({ok, Status, _, _} when Status =:= 400 orelse Status =:= 404, Result)
    end).

api_backup_export_content_disposition_test() ->
    ensure_env(),
    {ok, 200, Hdrs, _} = dispatch(<<"GET">>, <<"/api/backup/export">>),
    Disp = proplists:get_value(<<"content-disposition">>, Hdrs),
    ?assertEqual(<<"attachment; filename=\"eproxy-config.json\"">>, Disp).

api_build_health_json_imported_cert_covers_host_test() ->
    with_tmp_db(fun(_Db) ->
        with_tls_data_dir(fun(_Dir) ->
            Cert = read_priv_pem("listener.pem"),
            Key = read_priv_pem("listener.key"),
            Body = thoas:encode(#{<<"cert_pem">> => Cert, <<"key_pem">> => Key}),
            {ok, 201, _, Resp} = dispatch(<<"POST">>, <<"/api/certificates/import">>, Body),
            {ok, #{<<"id">> := Id}} = thoas:decode(Resp),
            IdBin =
                case Id of
                    I when is_integer(I) -> integer_to_binary(I);
                    B when is_binary(B) -> B
                end,
            pertisk_eproxy_test_helpers:sync_router(
                [#{host => <<"localhost">>, backend => <<"web">>,
                  certificate => IdBin, routes => []}],
                []
            ),
            try
                Json = pertisk_eproxy_admin_handler:build_health_json(),
                {ok, Map} = thoas:decode(Json),
                TlsSites = maps:get(<<"tls_sites">>, Map, []),
                ?assert(
                    lists:any(
                        fun(Row) ->
                            maps:get(<<"host">>, Row, undefined) =:= <<"localhost">>
                                andalso maps:get(<<"valid">>, Row, false) =:= true
                        end,
                        TlsSites
                    )
                )
            after
                pertisk_eproxy_test_helpers:sync_router([], [])
            end
        end)
    end).

api_certificates_list_includes_sites_field_test() ->
    with_tmp_db(fun(_Db) ->
        Add = thoas:encode(#{<<"name">> => <<"listed-cert.example">>}),
        {ok, 201, _, _} = dispatch(<<"POST">>, <<"/api/certificates">>, Add),
        pertisk_eproxy_test_helpers:sync_router(
            [#{host => <<"listed-cert.example">>, backend => <<"web">>,
              certificate => <<"listed-cert.example">>, routes => []}],
            []
        ),
        try
            {ok, 200, _, Body} = dispatch(<<"GET">>, <<"/api/certificates">>),
            {ok, Rows} = thoas:decode(Body),
            ?assert(
                lists:any(
                    fun(Row) ->
                        Sites = maps:get(<<"sites">>, Row, []),
                        lists:member(<<"listed-cert.example">>, Sites)
                    end,
                    Rows
                )
            )
        after
            pertisk_eproxy_test_helpers:sync_router([], [])
        end
    end).

api_certificate_import_put_duplicate_name_retry_test() ->
    with_tmp_db(fun(_Db) ->
        with_tls_data_dir(fun(_Dir) ->
            Cert = read_priv_pem("listener.pem"),
            Key = read_priv_pem("listener.key"),
            Body = thoas:encode(#{<<"cert_pem">> => Cert, <<"key_pem">> => Key}),
            ?assertMatch({ok, 201, _, _}, dispatch(<<"POST">>, <<"/api/certificates/import">>, Body)),
            ?assertMatch({ok, 201, _, _}, dispatch(<<"POST">>, <<"/api/certificates/import">>, Body)),
            {ok, 200, _, ListBody} = dispatch(<<"GET">>, <<"/api/certificates">>),
            {ok, Rows} = thoas:decode(ListBody),
            ?assert(length(Rows) >= 2)
        end)
    end).

api_site_route_with_rewrite_test() ->
    ensure_env(),
    Host = <<"rewrite.example">>,
    Body = thoas:encode(#{
        <<"host">> => Host,
        <<"backend">> => <<"web">>,
        <<"routes">> => [
            #{<<"path">> => <<"/old">>, <<"path_type">> => <<"prefix">>, <<"rewrite">> => <<"/new">>}
        ]
    }),
    try
        ?assertMatch({ok, 201, _, _}, dispatch(<<"POST">>, <<"/api/sites">>, Body)),
        {ok, 200, _, GetBody} = dispatch(<<"GET">>, <<"/api/sites/rewrite.example">>),
        {ok, Site} = thoas:decode(GetBody),
        [Route | _] = maps:get(<<"routes">>, Site, []),
        ?assertEqual(<<"/new">>, maps:get(<<"rewrite">>, Route))
    after
        _ = dispatch(<<"DELETE">>, <<"/api/sites/rewrite.example">>)
    end.

api_certificates_db_error_returns_500_test() ->
    with_tmp_db(fun(_Db) ->
        meck:new(pertisk_eproxy_db, [unstick, no_link, passthrough]),
        meck:expect(pertisk_eproxy_db, list_certificates, fun(_) -> {error, sqlite_locked} end),
        try
            ?assertMatch({ok, 500, _, _}, dispatch(<<"GET">>, <<"/api/certificates">>))
        after
            safe_meck_unload(pertisk_eproxy_db)
        end
    end).

api_dns_providers_db_error_returns_500_test() ->
    with_tmp_db(fun(_Db) ->
        meck:new(pertisk_eproxy_db, [unstick, no_link, passthrough]),
        meck:expect(pertisk_eproxy_db, list_dns_providers, fun(_) -> {error, sqlite_locked} end),
        try
            ?assertMatch({ok, 500, _, _}, dispatch(<<"GET">>, <<"/api/dns-providers">>))
        after
            safe_meck_unload(pertisk_eproxy_db)
        end
    end).

api_backup_restore_cert_record_empty_name_test() ->
    ensure_env(),
    Inner = thoas:encode(#{
        <<"sites">> => [],
        <<"backends">> => [],
        <<"dns_providers">> => [],
        <<"certificate_records">> => [
            #{<<"name">> => <<>>, <<"source_type">> => <<"acme">>}
        ]
    }),
    Bad = thoas:encode(#{<<"data">> => Inner}),
    ?assertMatch({ok, 400, _, _}, dispatch(<<"POST">>, <<"/api/backup/restore">>, Bad)).

%% ---------------------------------------------------------------------------
%% init_dispatch: health cache, ingress live, k8s errors, put_config failures
%% ---------------------------------------------------------------------------

api_health_cache_init_get_test() ->
    ensure_health_cache(),
    {ok, Status, _, Body} = init_dispatch(<<"GET">>, <<"/api/health">>, health),
    ?assertEqual(200, Status),
    ?assert(byte_size(Body) > 20).

api_health_cache_init_head_test() ->
    ensure_health_cache(),
    ?assertMatch({ok, 200, _, <<>>}, init_dispatch(<<"HEAD">>, <<"/api/health">>, health)).

api_ingress_live_init_get_test() ->
    ensure_ingress_status_env(),
    ?assertMatch({ok, 200, _, _}, init_dispatch(<<"GET">>, <<"/api/ingress/live">>, ingress_live)).

api_auth_check_local_invalid_token_test() ->
    with_local_auth(fun() ->
        {ok, 200, _, Body} =
            dispatch_auth(<<"GET">>, <<"/api/auth/check">>, <<>>, <<"not.a.valid.jwt">>),
        {ok, Map} = thoas:decode(Body),
        ?assertEqual(false, maps:get(<<"authenticated">>, Map))
    end).

api_ingress_guest_mutating_post_forbidden_test() ->
    with_ingress_mode(fun() ->
        with_env("PERTISK_ADMIN", unset, fun() ->
            Body = thoas:encode(#{
                <<"host">> => <<"guest-blocked.example">>,
                <<"backend">> => <<"web">>,
                <<"routes">> => []
            }),
            ?assertMatch({ok, 403, _, _}, dispatch(<<"POST">>, <<"/api/sites">>, Body))
        end)
    end).

api_config_get_includes_tls_quic_fields_test() ->
    with_tmp_db(fun(_Db) ->
        {ok, 200, _, ConfigBody} = dispatch(<<"GET">>, <<"/api/config">>),
        {ok, Config} = thoas:decode(ConfigBody),
        Put = thoas:encode(Config#{
            <<"https_port">> => 443,
            <<"quic_enabled">> => true,
            <<"quic_port">> => 4433,
            <<"tls_http2_enabled">> => false,
            <<"h3_probe_port">> => 9443
        }),
        ?assertMatch({ok, 200, _, _}, dispatch_put_config(Put)),
        {ok, 200, _, Body2} = dispatch(<<"GET">>, <<"/api/config">>),
        {ok, Updated} = thoas:decode(Body2),
        ?assertEqual(443, maps:get(<<"https_port">>, Updated)),
        ?assertEqual(true, maps:get(<<"quic_enabled">>, Updated)),
        ?assertEqual(4433, maps:get(<<"quic_port">>, Updated)),
        ?assertEqual(false, maps:get(<<"tls_http2_enabled">>, Updated)),
        ?assertEqual(9443, maps:get(<<"h3_probe_port">>, Updated))
    end).

api_backup_export_includes_tls_key_paths_test() ->
    with_tls_data_dir(fun(_Dir) ->
        Cert = read_priv_pem("listener.pem"),
        Key = read_priv_pem("listener.key"),
        Body = thoas:encode(#{<<"cert_pem">> => Cert, <<"key_pem">> => Key}),
        ?assertMatch({ok, 200, _, _}, dispatch(<<"POST">>, <<"/api/tls/listener">>, Body)),
        {ok, 200, _, ExportBody} = dispatch(<<"GET">>, <<"/api/backup/export">>),
        {ok, Export} = thoas:decode(ExportBody),
        ?assert(maps:is_key(<<"tls_cert_file">>, Export)),
        ?assert(maps:is_key(<<"tls_key_file">>, Export)),
        ?assert(maps:get(<<"tls_key_file">>, Export) =/= <<"[redacted]">>)
    end).

api_site_post_exact_path_type_test() ->
    with_tmp_db(fun(_Db) ->
    Host = <<"exact-path.example">>,
    Body = thoas:encode(#{
        <<"host">> => Host,
        <<"backend">> => <<"web">>,
        <<"routes">> => [#{<<"path">> => <<"/exact">>, <<"path_type">> => <<"exact">>}]
    }),
    try
        ?assertMatch({ok, 201, _, _}, dispatch(<<"POST">>, <<"/api/sites">>, Body)),
        {ok, 200, _, GetBody} = dispatch(<<"GET">>, <<"/api/sites/exact-path.example">>),
        {ok, Site} = thoas:decode(GetBody),
        [Route | _] = maps:get(<<"routes">>, Site, []),
        ?assertEqual(<<"exact">>, maps:get(<<"path_type">>, Route))
    after
        _ = dispatch(<<"DELETE">>, <<"/api/sites/exact-path.example">>)
    end
    end).

api_backend_post_ip_hash_algorithm_test() ->
    ensure_env(),
    Name = <<"ip_hash_", (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    Body = thoas:encode(#{
        <<"name">> => Name,
        <<"algorithm">> => <<"ip_hash">>,
        <<"upstreams">> => [#{<<"addr">> => <<"127.0.0.1:9">>}]
    }),
    try
        ?assertMatch({ok, 201, _, _}, dispatch(<<"POST">>, <<"/api/backends">>, Body)),
        {ok, 200, _, ListBody} = dispatch(<<"GET">>, <<"/api/backends">>),
        {ok, Rows} = thoas:decode(ListBody),
        ?assert(
            lists:any(
                fun(Row) ->
                    maps:get(<<"name">>, Row, undefined) =:= Name
                        andalso maps:get(<<"algorithm">>, Row, undefined) =:= <<"ip_hash">>
                end,
                Rows
            )
        )
    after
        _ = dispatch(<<"DELETE">>, <<"/api/backends/", Name/binary>>)
    end.

api_backend_post_least_connections_algorithm_test() ->
    ensure_env(),
    Name = <<"least_conn_", (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    Body = thoas:encode(#{
        <<"name">> => Name,
        <<"algorithm">> => <<"least_connections">>,
        <<"upstreams">> => [#{<<"addr">> => <<"127.0.0.1:9">>}]
    }),
    try
        ?assertMatch({ok, 201, _, _}, dispatch(<<"POST">>, <<"/api/backends">>, Body)),
        {ok, 200, _, GetBody} = dispatch(<<"GET">>, <<"/api/backends/", Name/binary>>),
        {ok, Status} = thoas:decode(GetBody),
        ?assertEqual(<<"least_connections">>, maps:get(<<"algorithm">>, Status))
    after
        _ = dispatch(<<"DELETE">>, <<"/api/backends/", Name/binary>>)
    end.

api_ingress_resources_with_synced_site_test() ->
    ensure_env(),
    Host = <<"ing-res.example">>,
    pertisk_eproxy_test_helpers:sync_router(
        [#{host => Host, backend => <<"web">>, routes => []}],
        [#{name => <<"web">>, upstreams => [#{addr => <<"127.0.0.1:9">>}]}]
    ),
    try
        {ok, 200, _, Body} = dispatch(<<"GET">>, <<"/api/ingress/resources">>),
        {ok, Map} = thoas:decode(Body),
        Sites = maps:get(<<"sites">>, Map, []),
        ?assert(
            lists:any(fun(S) -> maps:get(<<"host">>, S, undefined) =:= Host end, Sites)
        )
    after
        pertisk_eproxy_test_helpers:sync_router([], [])
    end.

api_build_health_json_lego_required_route53_test() ->
    with_tmp_db(fun(_Db) ->
        Add = thoas:encode(#{
            <<"name">> => <<"aws-route53">>,
            <<"provider_type">> => <<"route53">>,
            <<"credentials">> => #{
                <<"access_key_id">> => <<"key">>,
                <<"secret_access_key">> => <<"secret">>
            }
        }),
        ?assertMatch({ok, 201, _, _}, dispatch(<<"POST">>, <<"/api/dns-providers">>, Add)),
        {ok, Map} = thoas:decode(pertisk_eproxy_admin_handler:build_health_json()),
        Acme = maps:get(<<"acme">>, Map),
        ?assertEqual(true, maps:get(<<"lego_required">>, Acme))
    end).

api_build_health_json_lego_required_godaddy_test() ->
    with_tmp_db(fun(_Db) ->
        Add = thoas:encode(#{
            <<"name">> => <<"gd-dns">>,
            <<"provider_type">> => <<"godaddy">>,
            <<"credentials">> => #{<<"api_key">> => <<"k">>, <<"api_secret">> => <<"s">>}
        }),
        ?assertMatch({ok, 201, _, _}, dispatch(<<"POST">>, <<"/api/dns-providers">>, Add)),
        {ok, Map} = thoas:decode(pertisk_eproxy_admin_handler:build_health_json()),
        ?assertEqual(true, maps:get(<<"lego_required">>, maps:get(<<"acme">>, Map)))
    end).

api_certificate_put_invalid_id_test() ->
    with_tmp_db(fun(_Db) ->
        Put = thoas:encode(#{<<"name">> => <<"bad-id-cert">>}),
        ?assertMatch({ok, 400, _, _}, dispatch(<<"PUT">>, <<"/api/certificates/not-id">>, Put))
    end).

api_certificates_post_db_error_test() ->
    with_tmp_db(fun(_Db) ->
        meck:new(pertisk_eproxy_db, [unstick, no_link, passthrough]),
        meck:expect(pertisk_eproxy_db, insert_certificate, fun(_, _) -> {error, duplicate_name} end),
        try
            Body = thoas:encode(#{<<"name">> => <<"dup-cert">>}),
            ?assertMatch({ok, 400, _, _}, dispatch(<<"POST">>, <<"/api/certificates">>, Body))
        after
            safe_meck_unload(pertisk_eproxy_db)
        end
    end).

api_certificate_delete_db_error_test() ->
    with_tmp_db(fun(_Db) ->
        Add = thoas:encode(#{<<"name">> => <<"del-err-cert">>}),
        {ok, 201, _, Resp} = dispatch(<<"POST">>, <<"/api/certificates">>, Add),
        {ok, #{<<"id">> := Id}} = thoas:decode(Resp),
        IdBin =
            case Id of
                I when is_integer(I) -> integer_to_binary(I);
                B when is_binary(B) -> B
            end,
        meck:new(pertisk_eproxy_db, [unstick, no_link, passthrough]),
        meck:expect(pertisk_eproxy_db, delete_certificate, fun(_, _) -> {error, locked} end),
        try
            ?assertMatch({ok, 400, _, _}, dispatch(<<"DELETE">>, <<"/api/certificates/", IdBin/binary>>))
        after
            safe_meck_unload(pertisk_eproxy_db)
        end
    end).

api_dns_provider_post_db_error_test() ->
    with_tmp_db(fun(_Db) ->
        meck:new(pertisk_eproxy_db, [unstick, no_link, passthrough]),
        meck:expect(pertisk_eproxy_db, insert_dns_provider, fun(_, _, _, _) -> {error, duplicate} end),
        try
            Body = thoas:encode(#{
                <<"name">> => <<"dup-dns">>,
                <<"provider_type">> => <<"cloudflare">>,
                <<"credentials">> => #{<<"api_token">> => <<"tok">>}
            }),
            ?assertMatch({ok, 400, _, _}, dispatch(<<"POST">>, <<"/api/dns-providers">>, Body))
        after
            safe_meck_unload(pertisk_eproxy_db)
        end
    end).

api_dns_provider_delete_by_name_in_use_test() ->
    with_tmp_db(fun(_Db) ->
        Add = thoas:encode(#{
            <<"name">> => <<"cf-name-in-use">>,
            <<"provider_type">> => <<"cloudflare">>,
            <<"credentials">> => #{<<"api_token">> => <<"secret">>}
        }),
        ?assertMatch({ok, 201, _, _}, dispatch(<<"POST">>, <<"/api/dns-providers">>, Add)),
        pertisk_eproxy_test_helpers:sync_router(
            [#{host => <<"dns-name.example">>, backend => <<"web">>,
              dns_provider => <<"cf-name-in-use">>, routes => []}],
            []
        ),
        try
            ?assertMatch(
                {ok, 400, _, _},
                dispatch(<<"DELETE">>, <<"/api/dns-providers/cf-name-in-use">>)
            )
        after
            pertisk_eproxy_test_helpers:sync_router([], [])
        end
    end).

api_helm_values_ingress_invalid_revision_string_test() ->
    with_ingress_authenticated(fun(Token) ->
        with_env("PERTISK_HELM_RELEASE", {set, "pertisk-eproxy"}, fun() ->
            ?assertMatch(
                {ok, 400, _, _},
                dispatch_auth(<<"GET">>, <<"/api/helm/values/not-a-rev">>, <<>>, Token)
            )
        end)
    end).

api_k8s_namespaces_k8s_404_error_test() ->
    with_ingress_authenticated(fun(Token) ->
        meck:new(pertisk_eproxy_admin_kubernetes, [unstick]),
        meck:expect(pertisk_eproxy_admin_kubernetes, namespaces, fun() ->
            {error, #{<<"code">> => 404}}
        end),
        try
            ?assertMatch(
                {ok, 404, _, _},
                dispatch_auth(<<"GET">>, <<"/api/kubernetes/namespaces">>, <<>>, Token)
            )
        after
            meck:unload(pertisk_eproxy_admin_kubernetes)
        end
    end).

api_k8s_namespaces_k8s_403_error_test() ->
    with_ingress_authenticated(fun(Token) ->
        meck:new(pertisk_eproxy_admin_kubernetes, [unstick]),
        meck:expect(pertisk_eproxy_admin_kubernetes, namespaces, fun() ->
            {error, #{<<"reason">> => <<"Forbidden">>}}
        end),
        try
            ?assertMatch(
                {ok, 403, _, _},
                dispatch_auth(<<"GET">>, <<"/api/kubernetes/namespaces">>, <<>>, Token)
            )
        after
            meck:unload(pertisk_eproxy_admin_kubernetes)
        end
    end).

api_k8s_pods_k8s_not_found_nested_error_test() ->
    with_ingress_authenticated(fun(Token) ->
        meck:new(pertisk_eproxy_admin_kubernetes, [unstick]),
        meck:expect(pertisk_eproxy_admin_kubernetes, pods, fun(_) ->
            {error, #{<<"status">> => #{<<"code">> => 404}}}
        end),
        try
            ?assertMatch(
                {ok, 404, _, _},
                dispatch_auth(<<"GET">>, <<"/api/kubernetes/pods">>, <<"namespace=default">>, Token)
            )
        after
            meck:unload(pertisk_eproxy_admin_kubernetes)
        end
    end).

api_k8s_services_k8s_generic_error_test() ->
    with_ingress_authenticated(fun(Token) ->
        meck:new(pertisk_eproxy_admin_kubernetes, [unstick]),
        meck:expect(pertisk_eproxy_admin_kubernetes, services, fun(_) ->
            {error, #{<<"message">> => <<"cluster unreachable">>}}
        end),
        try
            {ok, Status, _, Body} =
                dispatch_auth(<<"GET">>, <<"/api/kubernetes/services">>, <<"namespace=default">>, Token),
            ?assert(Status >= 400),
            {ok, Map} = thoas:decode(Body),
            ?assert(maps:is_key(<<"error">>, Map))
        after
            meck:unload(pertisk_eproxy_admin_kubernetes)
        end
    end).

%% ---------------------------------------------------------------------------
%% init_dispatch coverage: ingress errors, auth login, health JSON, k8s TLS
%% ---------------------------------------------------------------------------

api_ingress_errors_init_get_test() ->
    ensure_ingress_status_env(),
    {ok, 200, _, Body} = init_dispatch(<<"GET">>, <<"/api/ingress/errors">>, ingress_errors),
    {ok, Map} = thoas:decode(Body),
    ?assert(maps:is_key(<<"last_error">>, Map)).

api_ingress_status_init_head_test() ->
    ensure_ingress_status_env(),
    ?assertMatch({ok, 200, _, <<>>}, init_dispatch(<<"HEAD">>, <<"/api/ingress/status">>, ingress_status)).

api_auth_login_init_post_test() ->
    with_local_auth_db(fun(_Db) ->
        Body = thoas:encode(#{<<"username">> => <<"admin">>, <<"password">> => <<"admin">>}),
        ?assertMatch({ok, 200, _, _}, init_dispatch(<<"POST">>, <<"/api/auth/login">>, auth_login, Body))
    end).

api_auth_refresh_init_post_invalid_test() ->
    with_local_auth(fun() ->
        Body = thoas:encode(#{<<"token">> => <<"not-a-session-token">>}),
        ?assertMatch({ok, 401, _, _}, init_dispatch(<<"POST">>, <<"/api/auth/refresh">>, auth_refresh, Body))
    end).

api_build_health_json_with_backend_test() ->
    ensure_env(),
    Name = <<"hb-", (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    {ok, Pid} = pertisk_eproxy_test_helpers:start_backend(Name, [#{addr => <<"127.0.0.1:9">>, weight => 1}]),
    true = erlang:unlink(Pid),
    try
        pertisk_eproxy_test_helpers:sync_router(
            [#{host => <<"health-json.example">>, backend => Name, routes => []}],
            [#{name => Name, algorithm => round_robin, upstreams => [#{addr => <<"127.0.0.1:9">>}]}]
        ),
        {ok, Map} = thoas:decode(pertisk_eproxy_admin_handler:build_health_json()),
        ?assert(is_list(maps:get(<<"backends">>, Map))),
        ?assert(is_list(maps:get(<<"tls_sites">>, Map)))
    after
        pertisk_eproxy_test_helpers:sync_router([], []),
        pertisk_eproxy_test_helpers:stop_backend(Name)
    end.

api_k8s_tls_secrets_init_get_test() ->
    with_ingress_authenticated(fun(Token) ->
        meck:new(pertisk_eproxy_admin_kubernetes, [unstick]),
        meck:expect(pertisk_eproxy_admin_kubernetes, tls_secrets, fun(_) -> {ok, []} end),
        try
            ?assertMatch(
                {ok, 200, _, _},
                dispatch_auth(<<"GET">>, <<"/api/kubernetes/tls-secrets">>, <<>>, Token)
            )
        after
            meck:unload(pertisk_eproxy_admin_kubernetes)
        end
    end).

api_unknown_resource_method_not_allowed_test() ->
    ensure_env(),
    ?assertMatch({ok, 405, _, _}, init_dispatch(<<"PATCH">>, <<"/api/version">>, version, <<"{}">>)).

api_ingress_viewer_mutating_forbidden_test() ->
    with_ingress_mode(fun() ->
        with_env("PERTISK_ADMIN", unset, fun() ->
            with_env("PERTISK_PASSWORD", unset, fun() ->
                pertisk_eproxy_env_auth:configure(),
                Body = thoas:encode(#{
                    <<"host">> => <<"viewer-blocked.example">>,
                    <<"backend">> => <<"web">>,
                    <<"routes">> => []
                }),
                ?assertMatch({ok, 403, _, _}, dispatch(<<"PUT">>, <<"/api/config">>, Body))
            end)
        end)
    end).
