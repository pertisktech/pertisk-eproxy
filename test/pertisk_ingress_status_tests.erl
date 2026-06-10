-module(pertisk_ingress_status_tests).

-include_lib("eunit/include/eunit.hrl").

ensure_ingress_tls() ->
    case whereis(pertisk_ingress_tls) of
        undefined -> {ok, _} = pertisk_ingress_tls:start_link();
        _ -> ok
    end.

init_and_record_success_test() ->
    ok = pertisk_ingress_status:init(),
    ensure_ingress_tls(),
    ok = pertisk_ingress_status:record_success([site], [be1, be2], [t1, t2, t3]),
    S = pertisk_ingress_status:snapshot(),
    ?assert(is_integer(maps:get(<<"last_success_at">>, S))),
    ?assertEqual(<<"connected">>, maps:get(<<"watcher">>, S)),
    ?assertEqual(null, maps:get(<<"last_error">>, S)).

record_error_test() ->
    ok = pertisk_ingress_status:init(),
    ensure_ingress_tls(),
    ok = pertisk_ingress_status:record_error(<<"boom">>),
    S = pertisk_ingress_status:snapshot(),
    ?assertEqual(<<"boom">>, maps:get(<<"last_error">>, S)).

set_leader_and_watcher_test() ->
    ok = pertisk_ingress_status:init(),
    ensure_ingress_tls(),
    ok = pertisk_ingress_status:set_leader(true),
    ok = pertisk_ingress_status:set_watcher_state(connected),
    S = pertisk_ingress_status:snapshot(),
    ?assertEqual(true, maps:get(<<"leader">>, S)),
    ?assertEqual(<<"connected">>, maps:get(<<"watcher">>, S)).

ready_from_runtime_when_ingress_disabled_test() ->
    Old = os:getenv("PERTISK_MODE"),
    os:unsetenv("PERTISK_MODE"),
    try
        ?assertEqual(ok, pertisk_ingress_status:ready_from_runtime())
    after
        case Old of false -> ok; V -> os:putenv("PERTISK_MODE", V) end
    end.

live_ok_test() ->
    ok = pertisk_ingress_status:init(),
    ?assertEqual(ok, pertisk_ingress_status:live_ok()).

ready_alias_test() ->
    ?assertEqual(pertisk_ingress_status:ready_from_runtime(), pertisk_ingress_status:ready()).

ready_from_runtime_ingress_enabled_paths_test() ->
    pertisk_eproxy_test_helpers:ensure_config(),
    ensure_ingress_tls(),
    pertisk_ingress_tls:clear(),
    ok = pertisk_ingress_status:init(),
    OldSites = pertisk_eproxy_config:get_sites(),
    OldBackends = pertisk_eproxy_config:get_backends(),
    OldMode = os:getenv("PERTISK_MODE"),
    OldTlsDir = os:getenv("PERTISK_K8S_TLS_DIR"),
    TmpTlsDir = filename:join([
        os:getenv("TMPDIR", "/tmp"),
        "pertisk_status_ready_" ++ integer_to_list(erlang:unique_integer([positive]))
    ]),
    _ = file:del_dir_r(TmpTlsDir),
    os:putenv("PERTISK_MODE", "ingress"),
    os:putenv("PERTISK_K8S_TLS_DIR", TmpTlsDir),
    try
        ok = pertisk_ingress_status:set_watcher_state(error),
        ?assertMatch({error, _}, pertisk_ingress_status:ready_from_runtime()),
        ok = pertisk_ingress_status:set_watcher_state(connected),
        pertisk_eproxy_config:sync_ingress([], []),
        ?assertMatch({error, _}, pertisk_ingress_status:ready_from_runtime()),
        Site = #{host => <<"ready.example">>, backend => <<"web">>, routes => []},
        Backend = #{
            name => <<"web">>,
            algorithm => round_robin,
            upstreams => [#{addr => <<"127.0.0.1:8080">>, weight => 1}]
        },
        pertisk_eproxy_config:sync_ingress([Site], [Backend]),
        ?assertMatch({error, _}, pertisk_ingress_status:ready_from_runtime()),
        {CertPem, KeyPem} = listener_pems(),
        ok = pertisk_ingress_tls:set_hosts([<<"ready.example">>], {CertPem, KeyPem}),
        ?assertEqual(ok, pertisk_ingress_status:ready_from_runtime())
    after
        pertisk_eproxy_config:sync_ingress(OldSites, OldBackends),
        case OldMode of false -> os:unsetenv("PERTISK_MODE"); V -> os:putenv("PERTISK_MODE", V) end,
        case OldTlsDir of false -> os:unsetenv("PERTISK_K8S_TLS_DIR"); T -> os:putenv("PERTISK_K8S_TLS_DIR", T) end,
        _ = file:del_dir_r(TmpTlsDir)
    end.

ready_from_disk_tls_test() ->
    TmpDir = filename:join([
        os:getenv("TMPDIR", "/tmp"),
        "pertisk_status_tls_" ++ integer_to_list(erlang:unique_integer([positive]))
    ]),
    _ = file:del_dir_r(TmpDir),
    CertPath = filename:join([TmpDir, "default", "disk", "tls.crt"]),
    KeyPath = filename:join([TmpDir, "default", "disk", "tls.key"]),
    ok = filelib:ensure_dir(CertPath),
    Cmd = "openssl req -x509 -newkey rsa:2048 -keyout " ++ KeyPath ++
        " -out " ++ CertPath ++ " -days 1 -nodes -subj /CN=localhost 2>/dev/null",
    _ = os:cmd(Cmd),
    pertisk_eproxy_test_helpers:ensure_config(),
    ensure_ingress_tls(),
    pertisk_ingress_tls:clear(),
    ok = pertisk_ingress_status:init(),
    OldTls = os:getenv("PERTISK_K8S_TLS_DIR"),
    OldMode = os:getenv("PERTISK_MODE"),
    os:putenv("PERTISK_K8S_TLS_DIR", TmpDir),
    os:putenv("PERTISK_MODE", "ingress"),
    try
        Site = #{host => <<"disk.example">>, backend => <<"web">>, routes => []},
        Backend = #{
            name => <<"web">>,
            algorithm => round_robin,
            upstreams => [#{addr => <<"127.0.0.1:8080">>, weight => 1}]
        },
        pertisk_eproxy_config:sync_ingress([Site], [Backend]),
        ok = pertisk_ingress_status:set_watcher_state(connected),
        ?assertEqual(ok, pertisk_ingress_status:ready_from_runtime())
    after
        case OldTls of false -> os:unsetenv("PERTISK_K8S_TLS_DIR"); TlsV -> os:putenv("PERTISK_K8S_TLS_DIR", TlsV) end,
        case OldMode of false -> os:unsetenv("PERTISK_MODE"); ModeV -> os:putenv("PERTISK_MODE", ModeV) end
    end,
    _ = file:del_dir_r(TmpDir).

snapshot_namespace_and_class_test() ->
    ok = pertisk_ingress_status:init(),
    ensure_ingress_tls(),
    OldNs = os:getenv("PERTISK_K8S_NAMESPACE"),
    OldClass = os:getenv("PERTISK_K8S_INGRESS_CLASS"),
    os:putenv("PERTISK_K8S_NAMESPACE", "snap-ns"),
    os:putenv("PERTISK_K8S_INGRESS_CLASS", "*"),
    try
        S = pertisk_ingress_status:snapshot(),
        ?assertEqual(<<"snap-ns">>, maps:get(<<"namespace">>, S)),
        ?assertEqual(null, maps:get(<<"ingress_class">>, S))
    after
        case OldNs of false -> os:unsetenv("PERTISK_K8S_NAMESPACE"); NsV -> os:putenv("PERTISK_K8S_NAMESPACE", NsV) end,
        case OldClass of false -> os:unsetenv("PERTISK_K8S_INGRESS_CLASS"); ClassV -> os:putenv("PERTISK_K8S_INGRESS_CLASS", ClassV) end
    end.

record_error_formats_term_test() ->
    ok = pertisk_ingress_status:init(),
    ensure_ingress_tls(),
    ok = pertisk_ingress_status:record_error({failed, reason}),
    S = pertisk_ingress_status:snapshot(),
    ?assert(is_binary(maps:get(<<"last_error">>, S))).

listener_pems() ->
    CertPath = filename:join([code:priv_dir(pertisk_eproxy), "tls", "listener.pem"]),
    KeyPath = filename:join([code:priv_dir(pertisk_eproxy), "tls", "listener.key"]),
    {ok, CertPem} = file:read_file(CertPath),
    {ok, KeyPem} = file:read_file(KeyPath),
    {CertPem, KeyPem}.
