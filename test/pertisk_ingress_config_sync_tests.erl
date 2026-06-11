-module(pertisk_ingress_config_sync_tests).

-include_lib("eunit/include/eunit.hrl").

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

with_ingress_env(Fun) ->
    OldSync = application:get_env(pertisk_eproxy, ingress_sync_sig, undefined),
    OldReload = application:get_env(pertisk_eproxy, ingress_tls_reload_sig, undefined),
    try
        application:unset_env(pertisk_eproxy, ingress_sync_sig),
        application:unset_env(pertisk_eproxy, ingress_tls_reload_sig),
        Fun()
    after
        restore_app_env(pertisk_eproxy, ingress_sync_sig, OldSync),
        restore_app_env(pertisk_eproxy, ingress_tls_reload_sig, OldReload)
    end.

restore_app_env(App, Key, undefined) ->
    application:unset_env(App, Key);
restore_app_env(App, Key, {ok, Val}) ->
    application:set_env(App, Key, Val).

ensure_ingress_tls() ->
    case whereis(pertisk_ingress_tls) of
        undefined -> {ok, _} = pertisk_ingress_tls:start_link();
        _ -> ok
    end.

ensure_status() ->
    ok = pertisk_ingress_status:init().

with_fixture(Fun) ->
    pertisk_eproxy_test_helpers:ensure_config(),
    ensure_ingress_tls(),
    ensure_status(),
    BaseConfig = pertisk_eproxy_config:get_config(),
    PortBase = 20000 + (erlang:phash2(self()) rem 10000),
    TestConfig = BaseConfig#{
        https_port => PortBase,
        quic_port => PortBase + 1,
        h3_api_gateway_enabled => false,
        quic_enabled => false
    },
    _ = catch pertisk_eproxy_test_helpers:put_config_retry(TestConfig),
    try
        with_ingress_env(Fun)
    after
        _ = catch pertisk_eproxy_test_helpers:put_config_retry(BaseConfig)
    end.

listener_pems() ->
  CertPath = filename:join([code:priv_dir(pertisk_eproxy), "tls", "listener.pem"]),
  KeyPath = filename:join([code:priv_dir(pertisk_eproxy), "tls", "listener.key"]),
  {ok, CertPem} = file:read_file(CertPath),
  {ok, KeyPem} = file:read_file(KeyPath),
  {CertPem, KeyPem}.

sample_site() ->
    #{
        host => <<"sync.example">>,
        backend => <<"web">>,
        routes => []
    }.

sample_backend() ->
    #{
        name => <<"web">>,
        algorithm => round_robin,
        upstreams => [#{addr => <<"127.0.0.1:8080">>, weight => 1}]
    }.

tls_entry(Hosts, Ns, Secret, CertPem, KeyPem) ->
    #{
        hosts => Hosts,
        cert_pem => CertPem,
        key_pem => KeyPem,
        namespace => Ns,
        secret => Secret
    }.

apply_reconcile_result_test() ->
    with_fixture(fun() ->
        Payload = #{sites => [], backends => [], tls => []},
        ?assertEqual(ok, pertisk_ingress_config_sync:apply_reconcile_result(Payload))
    end).

apply_empty_lists_test() ->
    with_fixture(fun() ->
        Payload = #{sites => [], backends => [], tls => []},
        ?assertEqual(ok, pertisk_ingress_config_sync:apply(Payload)),
        ?assertEqual(ok, pertisk_ingress_config_sync:apply(Payload))
    end).

apply_syncs_sites_and_backends_test() ->
    with_fixture(fun() ->
        Site = sample_site(),
        Backend = sample_backend(),
        Payload = #{sites => [Site], backends => [Backend], tls => []},
        ?assertEqual(ok, pertisk_ingress_config_sync:apply(Payload)),
        ?assertEqual([Site], pertisk_eproxy_config:get_sites()),
        ?assertEqual([Backend], pertisk_eproxy_config:get_backends())
    end).

apply_skips_unchanged_sites_backends_test() ->
    with_fixture(fun() ->
        Site = sample_site(),
        Backend = sample_backend(),
        Payload = #{sites => [Site], backends => [Backend], tls => []},
        ?assertEqual(ok, pertisk_ingress_config_sync:apply(Payload)),
        ?assertEqual(ok, pertisk_ingress_config_sync:apply(Payload))
    end).

apply_syncs_tls_entries_test() ->
    with_fixture(fun() ->
        {CertPem, KeyPem} = listener_pems(),
        Tls = [tls_entry([<<"tls.example">>], <<"default">>, <<"listener">>, CertPem, KeyPem)],
        Payload = #{sites => [], backends => [], tls => Tls},
        ?assertEqual(ok, pertisk_ingress_config_sync:apply(Payload)),
        ?assert(lists:member("tls.example", pertisk_ingress_tls:all_hosts()))
    end).

apply_empty_tls_keeps_cached_hosts_test() ->
    with_fixture(fun() ->
        {CertPem, KeyPem} = listener_pems(),
        Tls = [tls_entry([<<"cached.example">>], <<"default">>, <<"cached">>, CertPem, KeyPem)],
        ok = pertisk_ingress_config_sync:apply(#{sites => [], backends => [], tls => Tls}),
        ?assert(lists:member("cached.example", pertisk_ingress_tls:all_hosts())),
        ok = pertisk_ingress_config_sync:apply(#{sites => [], backends => [], tls => []}),
        ?assert(lists:member("cached.example", pertisk_ingress_tls:all_hosts()))
    end).

apply_tls_replaces_hosts_test() ->
    with_fixture(fun() ->
        {CertPem, KeyPem} = listener_pems(),
        First = [tls_entry([<<"old.example">>], <<"default">>, <<"old">>, CertPem, KeyPem)],
        Second = [tls_entry([<<"new.example">>], <<"default">>, <<"new">>, CertPem, KeyPem)],
        ok = pertisk_ingress_config_sync:apply(#{sites => [], backends => [], tls => First}),
        ok = pertisk_ingress_config_sync:apply(#{sites => [], backends => [], tls => Second}),
        Hosts = pertisk_ingress_tls:all_hosts(),
        ?assert(lists:member("new.example", Hosts)),
        ?assertNot(lists:member("old.example", Hosts))
    end).

apply_tls_invalid_material_warns_test() ->
    with_fixture(fun() ->
        Tls = [
            tls_entry(
                [<<"bad.example">>],
                <<"default">>,
                <<"bad">>,
                <<"not-a-cert">>,
                <<"not-a-key">>
            )
        ],
        ?assertEqual(ok, pertisk_ingress_config_sync:apply(#{sites => [], backends => [], tls => Tls}))
    end).

apply_tls_write_failure_test() ->
    with_fixture(fun() ->
        {CertPem, KeyPem} = listener_pems(),
        Tls = [tls_entry([<<"x.example">>], <<"default">>, <<"x">>, CertPem, KeyPem)],
        with_env("PERTISK_K8S_TLS_DIR", {set, "/dev/null"}, fun() ->
            ?assertMatch({error, {ingress_apply_failed, _, _, _}},
                pertisk_ingress_config_sync:apply(#{sites => [], backends => [], tls => Tls}))
        end)
    end).

write_restore_fixture(TmpTlsDir) ->
    Host = "restore.test",
    CertPath = filename:join([TmpTlsDir, "default", "disk", "tls.crt"]),
    KeyPath = filename:join([TmpTlsDir, "default", "disk", "tls.key"]),
    ok = filelib:ensure_dir(CertPath),
    Cmd = io_lib:format(
        "openssl req -x509 -newkey rsa:2048 -keyout ~s -out ~s -days 1 -nodes "
        "-subj \"/CN=~s\" -addext \"subjectAltName=DNS:~s\" 2>/dev/null",
        [KeyPath, CertPath, Host, Host]
    ),
    _ = os:cmd(lists:flatten(Cmd)),
    true = filelib:is_regular(CertPath),
    {ok, CertPem} = file:read_file(CertPath),
    {ok, KeyPem} = file:read_file(KeyPath),
    {Host, CertPem, KeyPem}.

apply_empty_tls_restore_from_disk_test() ->
    TmpTlsDir = filename:join([
        os:getenv("TMPDIR", "/tmp"),
        "pertisk_k8s_tls_" ++ integer_to_list(erlang:unique_integer([positive]))
    ]),
    _ = file:del_dir_r(TmpTlsDir),
    {Host, _CertPem, _KeyPem} = write_restore_fixture(TmpTlsDir),
    with_fixture(fun() ->
        Site = #{
            host => list_to_binary(Host),
            backend => <<"web">>,
            routes => [],
            ingress_namespace => <<"default">>
        },
        Backend = sample_backend(),
        with_env("PERTISK_K8S_TLS_DIR", {set, TmpTlsDir}, fun() ->
            ok = pertisk_ingress_config_sync:apply(#{
                sites => [Site],
                backends => [Backend],
                tls => []
            }),
            pertisk_ingress_tls:clear(),
            ok = pertisk_ingress_config_sync:apply(#{
                sites => [],
                backends => [],
                tls => []
            }),
            ?assert(lists:member(Host, pertisk_ingress_tls:all_hosts()))
        end)
    end),
    _ = file:del_dir_r(TmpTlsDir).

apply_reload_sig_stable_across_order_test() ->
    with_fixture(fun() ->
        SiteA = #{host => <<"a.example">>, backend => <<"web">>, routes => []},
        SiteB = #{host => <<"b.example">>, backend => <<"web">>, routes => []},
        Backend = sample_backend(),
        ?assertEqual(
            ok,
            pertisk_ingress_config_sync:apply(#{
                sites => [SiteA, SiteB],
                backends => [Backend],
                tls => []
            })
        ),
        ?assertEqual(
            ok,
            pertisk_ingress_config_sync:apply(#{
                sites => [SiteB, SiteA],
                backends => [Backend],
                tls => []
            })
        )
    end).
