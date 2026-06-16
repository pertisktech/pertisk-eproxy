-module(pertisk_eproxy_admin_management_snapshot_tests).

-include_lib("eunit/include/eunit.hrl").

-define(SNAPSHOT_TEST_DB, {pertisk_eproxy, admin_snapshot_test_db}).

ensure_config() ->
    application:ensure_all_started(lager),
    stop_config(),
    os:putenv("PERTISK_MODE", "proxy"),
    application:unset_env(pertisk_eproxy, mode),
    DbPath =
        case persistent_term:get(?SNAPSHOT_TEST_DB, undefined) of
            undefined ->
                P = pertisk_eproxy_test_helpers:tmp_db(),
                persistent_term:put(?SNAPSHOT_TEST_DB, P),
                P;
            P ->
                P
        end,
    application:set_env(pertisk_eproxy, db_file, DbPath),
    {ok, _} = pertisk_eproxy_config:start_link().

stop_config() ->
    case whereis(pertisk_eproxy_config) of
        undefined -> ok;
        Pid -> catch gen_server:stop(Pid), ok
    end.

start_ingress_config() ->
    application:ensure_all_started(lager),
    stop_config(),
    os:putenv("PERTISK_MODE", "ingress"),
    application:set_env(pertisk_eproxy, mode, ingress),
    {ok, _} = pertisk_eproxy_config:start_link().

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

snapshot_process_info_test() ->
    ensure_config(),
    S = pertisk_eproxy_admin_management_snapshot:snapshot(),
    PI = maps:get(<<"process_info">>, S),
    ?assert(is_map_key(<<"node">>, PI)),
    ?assert(is_map_key(<<"memory_breakdown_bytes">>, PI)).

snapshot_runtime_capabilities_test() ->
    ensure_config(),
    S = pertisk_eproxy_admin_management_snapshot:snapshot(),
    RC = maps:get(<<"runtime_capabilities">>, S),
    ?assert(is_map_key(<<"beam">>, RC)),
    ?assert(is_map_key(<<"jit">>, RC)).

snapshot_with_https_port_test() ->
    ensure_config(),
    C = pertisk_eproxy_config:get_config(),
    C2 = C#{https_port => 443, quic_enabled => true, quic_port => 4433},
    ok = pertisk_eproxy_test_helpers:put_config_retry(C2),
    try
        S = pertisk_eproxy_admin_management_snapshot:snapshot(),
        ?assertNotEqual(<<>>, maps:get(<<"https_addr">>, S)),
        Listeners = maps:get(<<"listeners">>, S),
        ?assert(
            lists:any(fun(L) -> maps:get(<<"id">>, L) =:= <<"proxy_https">> end, Listeners)
        ),
        ?assert(
            lists:any(fun(L) -> maps:get(<<"id">>, L) =:= <<"proxy_quic">> end, Listeners)
        )
    after
        ok = pertisk_eproxy_test_helpers:put_config_retry(C)
    end.

snapshot_cpu_after_init_sample_test() ->
    ensure_config(),
    ok = pertisk_eproxy_admin_management_snapshot:init_cpu_sample(),
    timer:sleep(2100),
    S = pertisk_eproxy_admin_management_snapshot:snapshot(),
    Cpu = maps:get(<<"process_cpu_usage_percent">>, S),
    ?assert(Cpu =:= null orelse is_float(Cpu) orelse is_integer(Cpu)).

app_version_from_env_test() ->
    Old = os:getenv("PERTISK_VERSION"),
    os:putenv("PERTISK_VERSION", "9.9.9-test"),
    try
        ?assertEqual(<<"9.9.9-test">>, pertisk_eproxy_admin_management_snapshot:app_version())
    after
        case Old of
            false -> os:unsetenv("PERTISK_VERSION");
            V -> os:putenv("PERTISK_VERSION", V)
        end
    end.

snapshot_ingress_mode_db_path_null_test() ->
    Old = os:getenv("PERTISK_MODE"),
    start_ingress_config(),
    try
        S = pertisk_eproxy_admin_management_snapshot:snapshot(),
        ?assertEqual(null, maps:get(<<"db_path">>, S)),
        ?assert(is_map(maps:get(<<"leader_election">>, S)))
    after
        stop_config(),
        application:unset_env(pertisk_eproxy, mode),
        case Old of
            false -> os:unsetenv("PERTISK_MODE");
            V -> os:putenv("PERTISK_MODE", V)
        end,
        ensure_config()
    end.

snapshot_metrics_listener_when_enabled_test() ->
    ensure_config(),
    C = pertisk_eproxy_config:get_config(),
    C2 = maps:put(metrics_enabled, true, C),
    ok = pertisk_eproxy_test_helpers:put_config_retry(C2),
    try
        S = pertisk_eproxy_admin_management_snapshot:snapshot(),
        Listeners = maps:get(<<"listeners">>, S),
        ?assert(
            lists:any(fun(L) -> maps:get(<<"id">>, L) =:= <<"metrics">> end, Listeners)
        )
    after
        ok = pertisk_eproxy_test_helpers:put_config_retry(C)
    end.

snapshot_h3_gateway_listener_test() ->
    ensure_config(),
    C = pertisk_eproxy_config:get_config(),
    C2 = C#{h3_api_gateway_enabled => true, https_port => 443},
    ok = pertisk_eproxy_test_helpers:put_config_retry(C2),
    try
        S = pertisk_eproxy_admin_management_snapshot:snapshot(),
        Listeners = maps:get(<<"listeners">>, S),
        ?assert(
            lists:any(fun(L) -> maps:get(<<"id">>, L) =:= <<"h3_api_gateway">> end, Listeners)
        ),
        Vers = maps:get(<<"http_versions">>, S),
        ?assert(lists:member(<<"http/3">>, Vers))
    after
        ok = pertisk_eproxy_test_helpers:put_config_retry(C)
    end.

snapshot_proxy_access_log_env_test() ->
    Old = os:getenv("PERTISK_PROXY_ACCESS_LOG"),
    os:putenv("PERTISK_PROXY_ACCESS_LOG", "false"),
    ensure_config(),
    try
        S = pertisk_eproxy_admin_management_snapshot:snapshot(),
        ?assertEqual(false, maps:get(<<"proxy_access_log">>, S))
    after
        case Old of
            false -> os:unsetenv("PERTISK_PROXY_ACCESS_LOG");
            V -> os:putenv("PERTISK_PROXY_ACCESS_LOG", V)
        end
    end.

snapshot_proxy_mode_db_path_test() ->
    Old = os:getenv("PERTISK_MODE"),
    os:putenv("PERTISK_MODE", "proxy"),
    ensure_config(),
    DbPath = pertisk_eproxy_test_helpers:tmp_db(),
    OldDb = application:get_env(pertisk_eproxy, db_file),
    application:set_env(pertisk_eproxy, db_file, DbPath),
    try
        S = pertisk_eproxy_admin_management_snapshot:snapshot(),
        ?assertEqual(list_to_binary(DbPath), maps:get(<<"db_path">>, S))
    after
        case OldDb of
            {ok, DbVal} -> application:set_env(pertisk_eproxy, db_file, DbVal);
            undefined -> application:unset_env(pertisk_eproxy, db_file)
        end,
        case Old of
            false -> os:unsetenv("PERTISK_MODE");
            ModeVal -> os:putenv("PERTISK_MODE", ModeVal)
        end
    end.

snapshot_management_tls_listener_test() ->
    ensure_config(),
    C = pertisk_eproxy_config:get_config(),
    C2 = maps:put(management_tls_enabled, true, C),
    ok = pertisk_eproxy_test_helpers:put_config_retry(C2),
    try
        S = pertisk_eproxy_admin_management_snapshot:snapshot(),
        Listeners = maps:get(<<"listeners">>, S),
        [Mgmt | _] = [L || L <- Listeners, maps:get(<<"id">>, L) =:= <<"management">>],
        ?assertEqual(true, maps:get(<<"tls">>, Mgmt)),
        Desc = maps:get(<<"description">>, Mgmt),
        ?assertNotEqual(nomatch, binary:match(Desc, <<"ALPN">>))
    after
        ok = pertisk_eproxy_test_helpers:put_config_retry(C)
    end.

snapshot_cpu_reuses_last_sample_within_interval_test() ->
    ensure_config(),
    ok = pertisk_eproxy_admin_management_snapshot:init_cpu_sample(),
    S1 = pertisk_eproxy_admin_management_snapshot:snapshot(),
    Cpu1 = maps:get(<<"process_cpu_usage_percent">>, S1),
    S2 = pertisk_eproxy_admin_management_snapshot:snapshot(),
    Cpu2 = maps:get(<<"process_cpu_usage_percent">>, S2),
    ?assertEqual(Cpu1, Cpu2).

snapshot_ingress_mode_config_test() ->
    Old = os:getenv("PERTISK_MODE"),
    start_ingress_config(),
    try
        S = pertisk_eproxy_admin_management_snapshot:snapshot(),
        ?assertEqual(<<"ingress">>, maps:get(<<"mode">>, S))
    after
        stop_config(),
        application:unset_env(pertisk_eproxy, mode),
        case Old of
            false -> os:unsetenv("PERTISK_MODE");
            V -> os:putenv("PERTISK_MODE", V)
        end,
        ensure_config()
    end.

snapshot_runtime_mode_proxy_not_custom_config_atom_test() ->
    ensure_config(),
    C = pertisk_eproxy_config:get_config(),
    C2 = maps:put(mode, edge, C),
    ok = pertisk_eproxy_test_helpers:put_config_retry(C2),
    try
        %% put_config normalizes proxy deployments to mode=proxy; snapshot reports runtime mode only.
        ?assertEqual(proxy, maps:get(mode, pertisk_eproxy_config:get_config())),
        S = pertisk_eproxy_admin_management_snapshot:snapshot(),
        ?assertEqual(<<"proxy">>, maps:get(<<"mode">>, S))
    after
        ok = pertisk_eproxy_test_helpers:put_config_retry(C)
    end.

snapshot_no_https_port_test() ->
    ensure_config(),
    C = pertisk_eproxy_config:get_config(),
    C2 = maps:without([https_port], C#{h3_api_gateway_enabled => false, quic_enabled => false}),
    ok = pertisk_eproxy_test_helpers:put_config_retry(C2),
    try
        S = pertisk_eproxy_admin_management_snapshot:snapshot(),
        ?assertEqual(<<>>, maps:get(<<"https_addr">>, S)),
        Listeners = maps:get(<<"listeners">>, S),
        ?assertNot(
            lists:any(fun(L) -> maps:get(<<"id">>, L) =:= <<"proxy_https">> end, Listeners)
        ),
        Vers = maps:get(<<"http_versions">>, S),
        ?assertEqual([<<"http/1.1">>], Vers)
    after
        ok = pertisk_eproxy_test_helpers:put_config_retry(C)
    end.

app_version_empty_env_test() ->
    Old = os:getenv("PERTISK_VERSION"),
    os:putenv("PERTISK_VERSION", "   "),
    try
        AppVsn = pertisk_eproxy_admin_management_snapshot:app_version(),
        ?assert(is_binary(AppVsn)),
        ?assert(byte_size(AppVsn) > 0)
    after
        case Old of
            false -> os:unsetenv("PERTISK_VERSION");
            OldVal -> os:putenv("PERTISK_VERSION", OldVal)
        end
    end.

snapshot_proxy_access_log_true_env_test() ->
    Old = os:getenv("PERTISK_PROXY_ACCESS_LOG"),
    os:putenv("PERTISK_PROXY_ACCESS_LOG", "true"),
    ensure_config(),
    try
        S = pertisk_eproxy_admin_management_snapshot:snapshot(),
        ?assertEqual(true, maps:get(<<"proxy_access_log">>, S))
    after
        case Old of
            false -> os:unsetenv("PERTISK_PROXY_ACCESS_LOG");
            V -> os:putenv("PERTISK_PROXY_ACCESS_LOG", V)
        end
    end.

snapshot_proxy_access_log_one_env_test() ->
    Old = os:getenv("PERTISK_PROXY_ACCESS_LOG"),
    os:putenv("PERTISK_PROXY_ACCESS_LOG", "1"),
    ensure_config(),
    try
        S = pertisk_eproxy_admin_management_snapshot:snapshot(),
        ?assertEqual(true, maps:get(<<"proxy_access_log">>, S))
    after
        case Old of
            false -> os:unsetenv("PERTISK_PROXY_ACCESS_LOG");
            V -> os:putenv("PERTISK_PROXY_ACCESS_LOG", V)
        end
    end.

snapshot_proxy_access_log_zero_env_test() ->
    Old = os:getenv("PERTISK_PROXY_ACCESS_LOG"),
    os:putenv("PERTISK_PROXY_ACCESS_LOG", "0"),
    ensure_config(),
    try
        S = pertisk_eproxy_admin_management_snapshot:snapshot(),
        ?assertEqual(false, maps:get(<<"proxy_access_log">>, S))
    after
        case Old of
            false -> os:unsetenv("PERTISK_PROXY_ACCESS_LOG");
            V -> os:putenv("PERTISK_PROXY_ACCESS_LOG", V)
        end
    end.

snapshot_proxy_access_log_config_false_test() ->
    Old = os:getenv("PERTISK_PROXY_ACCESS_LOG"),
    os:unsetenv("PERTISK_PROXY_ACCESS_LOG"),
    ensure_config(),
    C = pertisk_eproxy_config:get_config(),
    C2 = maps:put(proxy_access_log, false, C),
    ok = pertisk_eproxy_test_helpers:put_config_retry(C2),
    try
        S = pertisk_eproxy_admin_management_snapshot:snapshot(),
        ?assertEqual(false, maps:get(<<"proxy_access_log">>, S))
    after
        ok = pertisk_eproxy_test_helpers:put_config_retry(C),
        case Old of
            false -> ok;
            V -> os:putenv("PERTISK_PROXY_ACCESS_LOG", V)
        end
    end.

snapshot_db_file_binary_test() ->
    ensure_config(),
    DbPath = pertisk_eproxy_test_helpers:tmp_db(),
    OldDb = application:get_env(pertisk_eproxy, db_file),
    application:set_env(pertisk_eproxy, db_file, list_to_binary(DbPath)),
    try
        S = pertisk_eproxy_admin_management_snapshot:snapshot(),
        ?assertEqual(list_to_binary(DbPath), maps:get(<<"db_path">>, S))
    after
        case OldDb of
            {ok, DbVal} -> application:set_env(pertisk_eproxy, db_file, DbVal);
            undefined -> application:unset_env(pertisk_eproxy, db_file)
        end
    end.

snapshot_config_file_binary_test() ->
    Old = application:get_env(pertisk_eproxy, config_file),
    application:set_env(pertisk_eproxy, config_file, <<"config/custom.json">>),
    ensure_config(),
    try
        S = pertisk_eproxy_admin_management_snapshot:snapshot(),
        ?assertEqual(<<"config/custom.json">>, maps:get(<<"config_file">>, S))
    after
        case Old of
            {ok, Val} -> application:set_env(pertisk_eproxy, config_file, Val);
            undefined -> application:unset_env(pertisk_eproxy, config_file)
        end
    end.

snapshot_metrics_disabled_test() ->
    ensure_config(),
    C = pertisk_eproxy_config:get_config(),
    C2 = maps:put(metrics_enabled, false, C),
    ok = pertisk_eproxy_test_helpers:put_config_retry(C2),
    try
        S = pertisk_eproxy_admin_management_snapshot:snapshot(),
        Listeners = maps:get(<<"listeners">>, S),
        ?assertNot(
            lists:any(fun(L) -> maps:get(<<"id">>, L) =:= <<"metrics">> end, Listeners)
        )
    after
        ok = pertisk_eproxy_test_helpers:put_config_retry(C)
    end.

snapshot_h3_gateway_disabled_test() ->
    ensure_config(),
    C = pertisk_eproxy_config:get_config(),
    C2 = C#{h3_api_gateway_enabled => false, quic_enabled => false},
    ok = pertisk_eproxy_test_helpers:put_config_retry(C2),
    try
        S = pertisk_eproxy_admin_management_snapshot:snapshot(),
        Listeners = maps:get(<<"listeners">>, S),
        ?assertNot(
            lists:any(fun(L) -> maps:get(<<"id">>, L) =:= <<"h3_api_gateway">> end, Listeners)
        ),
        Vers = maps:get(<<"http_versions">>, S),
        ?assertNot(lists:member(<<"http/3">>, Vers))
    after
        ok = pertisk_eproxy_test_helpers:put_config_retry(C)
    end.

snapshot_cpu_null_without_init_test() ->
    ensure_config(),
    persistent_term:erase({pertisk_eproxy, management_cpu_prev}),
    persistent_term:erase({pertisk_eproxy, management_cpu_last_pct}),
    S = pertisk_eproxy_admin_management_snapshot:snapshot(),
    ?assertEqual(null, maps:get(<<"process_cpu_usage_percent">>, S)).

snapshot_h3_gateway_https_port_fallback_test() ->
    ensure_config(),
    C = pertisk_eproxy_config:get_config(),
    C2 = maps:without([quic_port], C#{h3_api_gateway_enabled => true, https_port => 8443}),
    ok = pertisk_eproxy_test_helpers:put_config_retry(C2),
    try
        S = pertisk_eproxy_admin_management_snapshot:snapshot(),
        Listeners = maps:get(<<"listeners">>, S),
        [Gw | _] = [L || L <- Listeners, maps:get(<<"id">>, L) =:= <<"h3_api_gateway">>],
        ?assertEqual(8443, maps:get(<<"port">>, Gw))
    after
        ok = pertisk_eproxy_test_helpers:put_config_retry(C)
    end.
