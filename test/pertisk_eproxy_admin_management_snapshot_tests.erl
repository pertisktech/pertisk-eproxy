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
    os:putenv("PERTISK_MODE", "ingress"),
    ensure_config(),
    try
        S = pertisk_eproxy_admin_management_snapshot:snapshot(),
        ?assertEqual(null, maps:get(<<"db_path">>, S)),
        ?assert(is_map(maps:get(<<"leader_election">>, S)))
    after
        case Old of
            false -> os:unsetenv("PERTISK_MODE");
            V -> os:putenv("PERTISK_MODE", V)
        end
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
