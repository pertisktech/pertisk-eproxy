-module(pertisk_eproxy_app_tests).

-include_lib("eunit/include/eunit.hrl").

%% ---------------------------------------------------------------------------
%% quic_noise_filter/2 tests
%% ---------------------------------------------------------------------------

quic_noise_filter_quic_shutdown_stops_test() ->
    Msg = {string, "Received unknown QUIC message ~p.", [{quic, shutdown, ref1, 0}]},
    ?assertEqual(stop, pertisk_eproxy_app:quic_noise_filter(#{msg => Msg}, #{})).

quic_noise_filter_no_msg_ignores_test() ->
    ?assertEqual(ignore, pertisk_eproxy_app:quic_noise_filter(#{}, #{})).

quic_noise_filter_other_string_ignores_test() ->
    Msg = {string, "Normal message ~p", [test]},
    ?assertEqual(ignore, pertisk_eproxy_app:quic_noise_filter(#{msg => Msg}, #{})).

quic_noise_filter_other_report_ignores_test() ->
    Msg = {report, #{some => data}},
    ?assertEqual(ignore, pertisk_eproxy_app:quic_noise_filter(#{msg => Msg}, #{})).

quic_noise_filter_quic_shutdown_report_stops_test() ->
    Msg = {report, #{format => "Received unknown QUIC message {quic,shutdown,ref1,0}"}},
    ?assertEqual(stop, pertisk_eproxy_app:quic_noise_filter(#{msg => Msg}, #{})).

quic_noise_filter_quic_shutdown_other_type_stops_test() ->
    Msg = "Received unknown QUIC message {quic,shutdown,ref,1}",
    ?assertEqual(stop, pertisk_eproxy_app:quic_noise_filter(#{msg => Msg}, #{})).

%% ---------------------------------------------------------------------------
%% reload_tls_listeners / reload_proxy_tls_listeners
%% ---------------------------------------------------------------------------

unload_mocks(Mods) ->
    pertisk_eproxy_test_helpers:unload_mocks(lists:reverse(Mods)).

reload_config() ->
    #{
        http_port => 18080,
        management_port => 19080,
        h3_api_gateway_enabled => false,
        h3_probe_enabled => false,
        quic_enabled => false
    }.

with_app_reload_mocks(Fun) ->
    pertisk_eproxy_test_helpers:ensure_lager(),
    pertisk_eproxy_test_helpers:ensure_config(),
    unload_mocks([
        cowboy, pertisk_eproxy_config, pertisk_eproxy_h3_api_gateway,
        pertisk_ingress_env, pertisk_eproxy_tls_paths
    ]),
    meck:new(cowboy, [unstick, no_link, no_passthrough_cover]),
    meck:new(pertisk_eproxy_config, [unstick, no_link, passthrough, no_passthrough_cover]),
    meck:new(pertisk_eproxy_h3_api_gateway, [unstick, no_link, no_passthrough_cover]),
    meck:new(pertisk_ingress_env, [unstick, no_link, no_passthrough_cover]),
    meck:new(pertisk_eproxy_tls_paths, [no_link, passthrough, no_passthrough_cover]),
    meck:expect(pertisk_eproxy_config, get_config, fun() -> reload_config() end),
    meck:expect(pertisk_eproxy_config, metrics_enabled, fun() -> false end),
    meck:expect(pertisk_eproxy_config, db_file, fun() -> pertisk_eproxy_test_helpers:tmp_db() end),
    meck:expect(pertisk_ingress_env, ingress_mode, fun() -> false end),
    meck:expect(pertisk_ingress_env, enabled, fun() -> false end),
    meck:expect(pertisk_eproxy_tls_paths, resolve_cert_file, fun(_) -> undefined end),
    meck:expect(pertisk_eproxy_tls_paths, resolve_key_file, fun(_) -> undefined end),
    meck:expect(pertisk_eproxy_tls_paths, default_cert_file, fun() -> "/nonexistent/cert.pem" end),
    meck:expect(pertisk_eproxy_tls_paths, default_key_file, fun() -> "/nonexistent/key.pem" end),
    meck:expect(cowboy, stop_listener, fun(_) -> ok end),
    meck:expect(cowboy, start_clear, fun(_, _, _) -> {ok, self()} end),
    meck:expect(cowboy, start_tls, fun(_, _, _) -> {ok, self()} end),
    meck:expect(pertisk_eproxy_h3_api_gateway, stop, fun() -> ok end),
    meck:expect(pertisk_eproxy_h3_api_gateway, stop_probe, fun() -> ok end),
    meck:expect(pertisk_eproxy_h3_api_gateway, start, fun(_) ->
        {error, {missing_tls_file, cert, "/x"}}
    end),
    meck:expect(pertisk_eproxy_h3_api_gateway, start_probe, fun(_) ->
        {error, {missing_tls_file, cert, "/x"}}
    end),
    try
        Fun()
    after
        unload_mocks([
            cowboy, pertisk_eproxy_config, pertisk_eproxy_h3_api_gateway,
            pertisk_ingress_env, pertisk_eproxy_tls_paths
        ])
    end.

reload_proxy_tls_listeners_ok_test() ->
    with_app_reload_mocks(fun() ->
        ?assertEqual(ok, pertisk_eproxy_app:reload_proxy_tls_listeners()),
        ?assert(meck:num_calls(cowboy, stop_listener, '_') >= 4),
        ?assertEqual(0, meck:num_calls(cowboy, start_tls, '_'))
    end).

reload_tls_listeners_ok_test() ->
    with_app_reload_mocks(fun() ->
        ?assertEqual(ok, pertisk_eproxy_app:reload_tls_listeners()),
        ?assert(meck:num_calls(cowboy, stop_listener, '_') >= 7),
        ?assert(meck:num_calls(cowboy, start_clear, '_') >= 3)
    end).

reload_proxy_tls_listeners_https_test() ->
    Cert = filename:join([code:priv_dir(pertisk_eproxy), "tls", "listener.pem"]),
    Key = filename:join([code:priv_dir(pertisk_eproxy), "tls", "listener.key"]),
    with_app_reload_mocks(fun() ->
        meck:expect(pertisk_eproxy_config, get_config, fun() ->
            (reload_config())#{
                https_port => 18443,
                tls_cert_file => Cert,
                tls_key_file => Key
            }
        end),
        ?assertEqual(ok, pertisk_eproxy_app:reload_proxy_tls_listeners()),
        ?assert(meck:num_calls(cowboy, start_tls, '_') >= 1)
    end).

stop_listeners_test() ->
    with_app_reload_mocks(fun() ->
        ?assertEqual(ok, pertisk_eproxy_app:stop(#{})),
        ?assert(meck:num_calls(cowboy, stop_listener, '_') >= 7)
    end).

%% ---------------------------------------------------------------------------
%% start/2 (proxy mode, heavily mocked)
%% ---------------------------------------------------------------------------

start_config() ->
    #{
        http_port => 18080,
        management_port => 19080,
        h3_api_gateway_enabled => false,
        h3_probe_enabled => false,
        quic_enabled => false
    }.

with_app_start_mocks(Fun) ->
    pertisk_eproxy_test_helpers:ensure_lager(),
    unload_mocks([
        cowboy, pertisk_eproxy_config, pertisk_eproxy_metrics,
        pertisk_eproxy_admin_management_snapshot, pertisk_eproxy_sup,
        pertisk_ingress_env, pertisk_eproxy_db,
        pertisk_eproxy_shell, pertisk_eproxy_auth0, pertisk_eproxy_h3_api_gateway,
        pertisk_eproxy_tls_paths
    ]),
    meck:new(cowboy, [unstick, no_link, no_passthrough_cover]),
    meck:new(pertisk_eproxy_config, [unstick, no_link, passthrough, no_passthrough_cover]),
    meck:new(pertisk_eproxy_metrics, [unstick, no_link, no_passthrough_cover]),
    meck:new(pertisk_eproxy_admin_management_snapshot, [unstick, no_link, no_passthrough_cover]),
    meck:new(pertisk_eproxy_sup, [unstick, no_link, no_passthrough_cover]),
    meck:new(pertisk_ingress_env, [unstick, no_link, no_passthrough_cover]),
    meck:new(pertisk_eproxy_db, [no_link, passthrough, no_passthrough_cover]),
    meck:new(pertisk_eproxy_shell, [unstick, no_link, no_passthrough_cover]),
    meck:new(pertisk_eproxy_auth0, [unstick, no_link, no_passthrough_cover]),
    meck:new(pertisk_eproxy_h3_api_gateway, [unstick, no_link, no_passthrough_cover]),
    meck:new(pertisk_eproxy_tls_paths, [no_link, passthrough, no_passthrough_cover]),
    meck:expect(pertisk_eproxy_config, get_config, fun() -> start_config() end),
    meck:expect(pertisk_eproxy_config, db_file, fun() -> pertisk_eproxy_test_helpers:tmp_db() end),
    meck:expect(pertisk_eproxy_config, data_dir, fun() -> "/tmp/pertisk-eproxy-test" end),
    meck:expect(pertisk_eproxy_config, metrics_enabled, fun() -> false end),
    meck:expect(pertisk_eproxy_config, metrics_listen, fun() -> {{127, 0, 0, 1}, 9190} end),
    meck:expect(pertisk_eproxy_metrics, setup, fun() -> ok end),
    meck:expect(pertisk_eproxy_admin_management_snapshot, init_cpu_sample, fun() -> ok end),
    meck:expect(pertisk_eproxy_sup, start_link, fun() -> {ok, self()} end),
    meck:expect(pertisk_ingress_env, ingress_mode, fun() -> false end),
    meck:expect(pertisk_ingress_env, enabled, fun() -> false end),
    meck:expect(pertisk_eproxy_db, ensure_ready, fun(_) -> {ok, ok} end),
    meck:expect(pertisk_eproxy_db, list_certificates, fun(_) -> {ok, []} end),
    meck:expect(pertisk_eproxy_tls_paths, resolve_cert_file, fun(_) -> undefined end),
    meck:expect(pertisk_eproxy_tls_paths, resolve_key_file, fun(_) -> undefined end),
    meck:expect(pertisk_eproxy_tls_paths, default_cert_file, fun() -> "/nonexistent/cert.pem" end),
    meck:expect(pertisk_eproxy_tls_paths, default_key_file, fun() -> "/nonexistent/key.pem" end),
    meck:expect(pertisk_eproxy_shell, openssl_executable, fun() -> {error, openssl_not_found} end),
    meck:expect(cowboy, stop_listener, fun(_) -> ok end),
    meck:expect(cowboy, start_clear, fun(_, _, _) -> {ok, self()} end),
    meck:expect(cowboy, start_tls, fun(_, _, _) -> {ok, self()} end),
    meck:expect(pertisk_eproxy_auth0, maybe_prefetch_jwks, fun() -> ok end),
    meck:expect(pertisk_eproxy_h3_api_gateway, stop, fun() -> ok end),
    meck:expect(pertisk_eproxy_h3_api_gateway, stop_probe, fun() -> ok end),
    meck:expect(pertisk_eproxy_h3_api_gateway, start, fun(_) ->
        {error, {missing_tls_file, cert, "/x"}}
    end),
    meck:expect(pertisk_eproxy_h3_api_gateway, start_probe, fun(_) ->
        {error, {missing_tls_file, cert, "/x"}}
    end),
    try
        Fun()
    after
        unload_mocks([
            cowboy, pertisk_eproxy_config, pertisk_eproxy_metrics,
            pertisk_eproxy_admin_management_snapshot, pertisk_eproxy_sup,
            pertisk_ingress_env, pertisk_eproxy_db,
            pertisk_eproxy_shell, pertisk_eproxy_auth0, pertisk_eproxy_h3_api_gateway,
            pertisk_eproxy_tls_paths
        ])
    end.

start_proxy_mode_mocked_test() ->
    with_app_start_mocks(fun() ->
        ?assertMatch({ok, _}, pertisk_eproxy_app:start(normal, [])),
        ?assertEqual(1, meck:num_calls(pertisk_eproxy_sup, start_link, '_')),
        ?assertEqual(1, meck:num_calls(pertisk_eproxy_metrics, setup, '_')),
        ?assertEqual(1, meck:num_calls(pertisk_eproxy_auth0, maybe_prefetch_jwks, '_')),
        ?assert(meck:num_calls(cowboy, start_clear, '_') >= 3),
        ?assertEqual(1, meck:num_calls(pertisk_eproxy_db, ensure_ready, '_'))
    end).

start_ingress_mode_skips_db_ensure_ready_test() ->
    with_app_start_mocks(fun() ->
        meck:expect(pertisk_ingress_env, ingress_mode, fun() -> true end),
        meck:expect(pertisk_ingress_env, enabled, fun() -> true end),
        meck:new(pertisk_eproxy_env_auth, [unstick, no_link, no_passthrough_cover]),
        meck:expect(pertisk_eproxy_env_auth, configure, fun() -> ok end),
        try
            ?assertMatch({ok, _}, pertisk_eproxy_app:start(normal, [])),
            ?assertEqual(0, meck:num_calls(pertisk_eproxy_db, ensure_ready, '_')),
            ?assertEqual({ok, ingress}, application:get_env(pertisk_eproxy, mode))
        after
            application:unset_env(pertisk_eproxy, mode),
            unload_mocks([pertisk_eproxy_env_auth])
        end
    end).

start_with_metrics_enabled_test() ->
    with_app_start_mocks(fun() ->
        meck:expect(pertisk_eproxy_config, get_config, fun() ->
            (start_config())#{
                metrics_enabled => true,
                metrics_addr => {127, 0, 0, 1},
                metrics_port => 9190
            }
        end),
        meck:expect(pertisk_eproxy_config, metrics_enabled, fun() -> true end),
        meck:expect(pertisk_eproxy_config, metrics_listen, fun() -> {{127, 0, 0, 1}, 9190} end),
        ?assertMatch({ok, _}, pertisk_eproxy_app:start(normal, [])),
        ?assertEqual(1, meck:num_calls(cowboy, start_clear, [metrics, '_', '_']))
    end).

reload_ipv6_partial_failure_test() ->
    with_app_reload_mocks(fun() ->
        meck:expect(cowboy, start_clear, fun(Name, _TransOpts, _ProtoOpts) ->
            case Name of
                http6 -> {error, eacces};
                _ -> {ok, self()}
            end
        end),
        ?assertEqual(ok, pertisk_eproxy_app:reload_tls_listeners()),
        ?assertEqual(1, meck:num_calls(cowboy, start_clear, [http6, '_', '_']))
    end).

start_h3_gateway_already_started_test() ->
    with_app_start_mocks(fun() ->
        Cert = filename:join([code:priv_dir(pertisk_eproxy), "tls", "listener.pem"]),
        Key = filename:join([code:priv_dir(pertisk_eproxy), "tls", "listener.key"]),
        meck:expect(pertisk_eproxy_config, get_config, fun() ->
            (start_config())#{
                https_port => 18443,
                tls_cert_file => Cert,
                tls_key_file => Key,
                h3_api_gateway_enabled => true
            }
        end),
        meck:expect(pertisk_eproxy_h3_api_gateway, start, fun(_) ->
            {error, {already_started, self()}}
        end),
        meck:expect(pertisk_eproxy_h3_api_gateway, start_probe, fun(_) ->
            {error, {already_started, self()}}
        end),
        ?assertMatch({ok, _}, pertisk_eproxy_app:start(normal, [])),
        ?assertEqual(1, meck:num_calls(pertisk_eproxy_h3_api_gateway, start, '_'))
    end).

downstream_idle_timeout_clamp_test() ->
    with_app_start_mocks(fun() ->
        meck:expect(pertisk_eproxy_config, get_config, fun() ->
            (start_config())#{
                downstream_idle_timeout_ms => 1000,
                upstream_request_timeout_ms => 180000
            }
        end),
        meck:expect(cowboy, start_clear, fun(Name, _TransOpts, ProtoOpts) ->
            case Name of
                http4 -> self() ! {clamped_idle, maps:get(idle_timeout, ProtoOpts)};
                _ -> ok
            end,
            {ok, self()}
        end),
        ?assertMatch({ok, _}, pertisk_eproxy_app:start(normal, [])),
        receive
            {clamped_idle, 185000} -> ok
        after 1000 ->
            ?assert(false)
        end
    end).

start_db_bootstrap_failure_continues_test() ->
    with_app_start_mocks(fun() ->
        meck:expect(pertisk_eproxy_db, ensure_ready, fun(_) -> {error, db_failed} end),
        ?assertMatch({ok, _}, pertisk_eproxy_app:start(normal, [])),
        ?assertEqual(1, meck:num_calls(pertisk_eproxy_db, ensure_ready, '_'))
    end).

start_h3_gateway_start_error_test() ->
    with_app_start_mocks(fun() ->
        Cert = filename:join([code:priv_dir(pertisk_eproxy), "tls", "listener.pem"]),
        Key = filename:join([code:priv_dir(pertisk_eproxy), "tls", "listener.key"]),
        meck:expect(pertisk_eproxy_config, get_config, fun() ->
            (start_config())#{
                https_port => 18443,
                tls_cert_file => Cert,
                tls_key_file => Key,
                h3_api_gateway_enabled => true
            }
        end),
        meck:expect(pertisk_eproxy_h3_api_gateway, start, fun(_) -> {error, refused} end),
        ?assertMatch({ok, _}, pertisk_eproxy_app:start(normal, [])),
        ?assertEqual(1, meck:num_calls(pertisk_eproxy_h3_api_gateway, start, '_'))
    end).

start_h3_probe_disabled_test() ->
    with_app_start_mocks(fun() ->
        meck:expect(pertisk_eproxy_config, get_config, fun() ->
            (start_config())#{h3_probe_enabled => false}
        end),
        ?assertMatch({ok, _}, pertisk_eproxy_app:start(normal, [])),
        ?assertEqual(0, meck:num_calls(pertisk_eproxy_h3_api_gateway, start_probe, '_'))
    end).

start_https_ingress_no_tls_material_test() ->
    with_app_start_mocks(fun() ->
        meck:expect(pertisk_ingress_env, enabled, fun() -> true end),
        meck:expect(pertisk_eproxy_config, get_config, fun() ->
            (start_config())#{https_port => 18443}
        end),
        ?assertMatch({ok, _}, pertisk_eproxy_app:start(normal, [])),
        ?assertEqual(0, meck:num_calls(cowboy, start_tls, '_'))
    end).

start_metrics_port_conflict_test() ->
    with_app_start_mocks(fun() ->
        meck:expect(pertisk_eproxy_config, get_config, fun() ->
            (start_config())#{
                metrics_enabled => true,
                metrics_addr => {127, 0, 0, 1},
                metrics_port => 19080
            }
        end),
        meck:expect(pertisk_eproxy_config, metrics_enabled, fun() -> true end),
        meck:expect(pertisk_eproxy_config, metrics_listen, fun() -> {{127, 0, 0, 1}, 19080} end),
        ?assertMatch({ok, _}, pertisk_eproxy_app:start(normal, [])),
        ?assertEqual(0, meck:num_calls(cowboy, start_clear, [metrics, '_', '_']))
    end).

start_https_ipv4_bind_failure_test() ->
    with_app_reload_mocks(fun() ->
        Cert = filename:join([code:priv_dir(pertisk_eproxy), "tls", "listener.pem"]),
        Key = filename:join([code:priv_dir(pertisk_eproxy), "tls", "listener.key"]),
        meck:expect(pertisk_eproxy_config, get_config, fun() ->
            (reload_config())#{
                https_port => 18443,
                tls_cert_file => Cert,
                tls_key_file => Key
            }
        end),
        meck:expect(cowboy, start_tls, fun(https4, _, _) -> {error, eaddrinuse} end),
        ?assertEqual(ok, pertisk_eproxy_app:reload_proxy_tls_listeners()),
        ?assertEqual(1, meck:num_calls(cowboy, start_tls, [https4, '_', '_']))
    end).

reload_proxy_tls_http2_disabled_test() ->
    Cert = filename:join([code:priv_dir(pertisk_eproxy), "tls", "listener.pem"]),
    Key = filename:join([code:priv_dir(pertisk_eproxy), "tls", "listener.key"]),
    with_app_reload_mocks(fun() ->
        meck:expect(pertisk_eproxy_config, get_config, fun() ->
            (reload_config())#{
                https_port => 18443,
                tls_cert_file => Cert,
                tls_key_file => Key,
                tls_http2_enabled => false
            }
        end),
        ?assertEqual(ok, pertisk_eproxy_app:reload_proxy_tls_listeners()),
        ?assert(meck:num_calls(cowboy, start_tls, '_') >= 1)
    end).

start_generate_fake_tls_success_test() ->
    with_app_start_mocks(fun() ->
        DataDir = filename:join([
            os:getenv("TMPDIR", "/tmp"),
            "pertisk-app-tls-" ++ integer_to_list(erlang:unique_integer([positive]))
        ]),
        ok = file:make_dir(DataDir),
        meck:expect(pertisk_eproxy_config, data_dir, fun() -> DataDir end),
        meck:expect(pertisk_eproxy_shell, openssl_executable, fun() -> {ok, "openssl"} end),
        meck:expect(pertisk_eproxy_shell, os_cmd, fun(Cmd) ->
            _ = os:cmd(Cmd),
            <<>>
        end),
        try
            ?assertMatch({ok, _}, pertisk_eproxy_app:start(normal, [])),
            CertPath = filename:join([DataDir, "tls", "listener.pem"]),
            KeyPath = filename:join([DataDir, "tls", "listener.key"]),
            ?assert(filelib:is_file(CertPath)),
            ?assert(filelib:is_file(KeyPath))
        after
            _ = os:cmd("rm -rf " ++ DataDir)
        end
    end).

start_https_inferred_port_443_test() ->
    Cert = filename:join([code:priv_dir(pertisk_eproxy), "tls", "listener.pem"]),
    Key = filename:join([code:priv_dir(pertisk_eproxy), "tls", "listener.key"]),
    with_app_start_mocks(fun() ->
        meck:expect(pertisk_eproxy_config, get_config, fun() ->
            (start_config())#{
                tls_cert_file => Cert,
                tls_key_file => Key,
                h3_api_gateway_enabled => false,
                h3_probe_enabled => false
            }
        end),
        ?assertMatch({ok, _}, pertisk_eproxy_app:start(normal, [])),
        ?assert(meck:num_calls(cowboy, start_tls, '_') >= 1)
    end).

start_quic_enabled_with_cowboy_quic_test() ->
    case erlang:function_exported(cowboy, start_quic, 3) of
        false ->
            ok;
        true ->
            Cert = filename:join([code:priv_dir(pertisk_eproxy), "tls", "listener.pem"]),
            Key = filename:join([code:priv_dir(pertisk_eproxy), "tls", "listener.key"]),
            with_app_start_mocks(fun() ->
                meck:expect(pertisk_eproxy_config, get_config, fun() ->
                    (start_config())#{
                        https_port => 18443,
                        tls_cert_file => Cert,
                        tls_key_file => Key,
                        quic_enabled => true,
                        h3_api_gateway_enabled => false,
                        h3_probe_enabled => false
                    }
                end),
                meck:expect(cowboy, start_quic, fun(_, _, _) -> {ok, self()} end),
                ?assertMatch({ok, _}, pertisk_eproxy_app:start(normal, [])),
                ?assertEqual(1, meck:num_calls(cowboy, start_quic, '_'))
            end)
    end.

start_quic_missing_cowboy_export_test() ->
    Cert = filename:join([code:priv_dir(pertisk_eproxy), "tls", "listener.pem"]),
    Key = filename:join([code:priv_dir(pertisk_eproxy), "tls", "listener.key"]),
    with_app_start_mocks(fun() ->
        meck:expect(pertisk_eproxy_config, get_config, fun() ->
            (start_config())#{
                https_port => 18443,
                tls_cert_file => Cert,
                tls_key_file => Key,
                quic_enabled => true,
                h3_api_gateway_enabled => false,
                h3_probe_enabled => false
            }
        end),
        ?assertMatch({ok, _}, pertisk_eproxy_app:start(normal, [])),
        ?assertEqual(0, meck:num_calls(cowboy, start_quic, '_'))
    end).

start_metrics_listener_success_test() ->
    with_app_start_mocks(fun() ->
        meck:expect(pertisk_eproxy_config, get_config, fun() ->
            (start_config())#{
                metrics_enabled => true,
                metrics_addr => {127, 0, 0, 1},
                metrics_port => 9190
            }
        end),
        meck:expect(pertisk_eproxy_config, metrics_enabled, fun() -> true end),
        meck:expect(pertisk_eproxy_config, metrics_listen, fun() -> {{127, 0, 0, 1}, 9190} end),
        ?assertMatch({ok, _}, pertisk_eproxy_app:start(normal, [])),
        ?assertEqual(1, meck:num_calls(cowboy, start_clear, [metrics, '_', '_']))
    end).

start_https_ipv6_only_failure_test() ->
    Cert = filename:join([code:priv_dir(pertisk_eproxy), "tls", "listener.pem"]),
    Key = filename:join([code:priv_dir(pertisk_eproxy), "tls", "listener.key"]),
    with_app_start_mocks(fun() ->
        meck:expect(pertisk_eproxy_config, get_config, fun() ->
            (start_config())#{
                https_port => 18443,
                tls_cert_file => Cert,
                tls_key_file => Key
            }
        end),
        meck:expect(cowboy, start_tls, fun
            (https4, _, _) -> {ok, self()};
            (https6, _, _) -> {error, eacces}
        end),
        ?assertMatch({ok, _}, pertisk_eproxy_app:start(normal, [])),
        ?assertEqual(1, meck:num_calls(cowboy, start_tls, [https6, '_', '_']))
    end).

reload_proxy_tls_sni_site_cert_from_db_test() ->
    DbPath = pertisk_eproxy_test_helpers:tmp_db(),
    file:delete(DbPath),
    application:set_env(pertisk_eproxy, db_file, DbPath),
    ?assertMatch({ok, _}, pertisk_eproxy_db:init(DbPath)),
    TmpDir = filename:join([
        os:getenv("TMPDIR", "/tmp"),
        "pertisk-app-sni-" ++ integer_to_list(erlang:unique_integer([positive]))
    ]),
    ok = file:make_dir(TmpDir),
    CertFile = filename:join(TmpDir, "cert.pem"),
    KeyFile = filename:join(TmpDir, "key.pem"),
    ok = file:write_file(CertFile, <<"-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----">>),
    ok = file:write_file(KeyFile, <<"-----BEGIN PRIVATE KEY-----\nKEY\n-----END PRIVATE KEY-----">>),
    {ok, CertId} = pertisk_eproxy_db:insert_certificate_pem(DbPath, <<"site-cert">>, CertFile, KeyFile),
    Cert = filename:join([code:priv_dir(pertisk_eproxy), "tls", "listener.pem"]),
    Key = filename:join([code:priv_dir(pertisk_eproxy), "tls", "listener.key"]),
    try
        with_app_reload_mocks(fun() ->
            meck:expect(pertisk_eproxy_config, get_config, fun() ->
                (reload_config())#{
                    https_port => 18443,
                    tls_cert_file => Cert,
                    tls_key_file => Key,
                    sites => [
                        #{
                            host => <<"sni.example.com">>,
                            backend => <<"web">>,
                            certificate => integer_to_binary(CertId),
                            routes => []
                        }
                    ]
                }
            end),
            meck:expect(pertisk_eproxy_config, db_file, fun() -> DbPath end),
            ?assertEqual(ok, pertisk_eproxy_app:reload_proxy_tls_listeners()),
            ?assert(meck:num_calls(cowboy, start_tls, '_') >= 1)
        end)
    after
        _ = os:cmd("rm -rf " ++ TmpDir),
        file:delete(DbPath)
    end.

start_metrics_bind_eacces_test() ->
    with_app_start_mocks(fun() ->
        meck:expect(pertisk_eproxy_config, get_config, fun() ->
            (start_config())#{
                metrics_enabled => true,
                metrics_addr => {127, 0, 0, 1},
                metrics_port => 9190
            }
        end),
        meck:expect(pertisk_eproxy_config, metrics_enabled, fun() -> true end),
        meck:expect(pertisk_eproxy_config, metrics_listen, fun() -> {{127, 0, 0, 1}, 9190} end),
        meck:expect(cowboy, start_clear, fun
            (metrics, _, _) -> {error, eacces};
            (_, _, _) -> {ok, self()}
        end),
        ?assertMatch({ok, _}, pertisk_eproxy_app:start(normal, [])),
        ?assertEqual(1, meck:num_calls(cowboy, start_clear, [metrics, '_', '_']))
    end).

start_h3_probe_start_error_test() ->
    with_app_start_mocks(fun() ->
        Cert = filename:join([code:priv_dir(pertisk_eproxy), "tls", "listener.pem"]),
        Key = filename:join([code:priv_dir(pertisk_eproxy), "tls", "listener.key"]),
        meck:expect(pertisk_eproxy_config, get_config, fun() ->
            (start_config())#{
                https_port => 18443,
                tls_cert_file => Cert,
                tls_key_file => Key,
                h3_probe_enabled => true
            }
        end),
        meck:expect(pertisk_eproxy_h3_api_gateway, start_probe, fun(_) -> {error, refused} end),
        ?assertMatch({ok, _}, pertisk_eproxy_app:start(normal, [])),
        ?assertEqual(1, meck:num_calls(pertisk_eproxy_h3_api_gateway, start_probe, '_'))
    end).

downstream_idle_timeout_uses_configured_value_test() ->
    with_app_start_mocks(fun() ->
        meck:expect(pertisk_eproxy_config, get_config, fun() ->
            (start_config())#{
                downstream_idle_timeout_ms => 300000,
                upstream_request_timeout_ms => 180000
            }
        end),
        meck:expect(cowboy, start_clear, fun(Name, _TransOpts, ProtoOpts) ->
            case Name of
                http4 -> self() ! {idle_timeout, maps:get(idle_timeout, ProtoOpts)};
                _ -> ok
            end,
            {ok, self()}
        end),
        ?assertMatch({ok, _}, pertisk_eproxy_app:start(normal, [])),
        receive
            {idle_timeout, 300000} -> ok
        after 1000 ->
            ?assert(false)
        end
    end).

start_https_bind_generic_error_test() ->
    with_app_reload_mocks(fun() ->
        Cert = filename:join([code:priv_dir(pertisk_eproxy), "tls", "listener.pem"]),
        Key = filename:join([code:priv_dir(pertisk_eproxy), "tls", "listener.key"]),
        meck:expect(pertisk_eproxy_config, get_config, fun() ->
            (reload_config())#{
                https_port => 18443,
                tls_cert_file => Cert,
                tls_key_file => Key
            }
        end),
        meck:expect(cowboy, start_tls, fun(https4, _, _) -> {error, enoent} end),
        ?assertEqual(ok, pertisk_eproxy_app:reload_proxy_tls_listeners()),
        ?assertEqual(1, meck:num_calls(cowboy, start_tls, [https4, '_', '_']))
    end).

start_h3_gateway_success_test() ->
    with_app_start_mocks(fun() ->
        Cert = filename:join([code:priv_dir(pertisk_eproxy), "tls", "listener.pem"]),
        Key = filename:join([code:priv_dir(pertisk_eproxy), "tls", "listener.key"]),
        meck:expect(pertisk_eproxy_config, get_config, fun() ->
            (start_config())#{
                https_port => 18443,
                tls_cert_file => Cert,
                tls_key_file => Key,
                h3_api_gateway_enabled => true
            }
        end),
        meck:expect(pertisk_eproxy_h3_api_gateway, start, fun(_) -> {ok, self()} end),
        ?assertMatch({ok, _}, pertisk_eproxy_app:start(normal, [])),
        ?assertEqual(1, meck:num_calls(pertisk_eproxy_h3_api_gateway, start, '_'))
    end).

start_h3_probe_success_test() ->
    with_app_start_mocks(fun() ->
        Cert = filename:join([code:priv_dir(pertisk_eproxy), "tls", "listener.pem"]),
        Key = filename:join([code:priv_dir(pertisk_eproxy), "tls", "listener.key"]),
        meck:expect(pertisk_eproxy_config, get_config, fun() ->
            (start_config())#{
                https_port => 18443,
                tls_cert_file => Cert,
                tls_key_file => Key,
                h3_probe_enabled => true
            }
        end),
        meck:expect(pertisk_eproxy_h3_api_gateway, start_probe, fun(_) -> {ok, self()} end),
        ?assertMatch({ok, _}, pertisk_eproxy_app:start(normal, [])),
        ?assertEqual(1, meck:num_calls(pertisk_eproxy_h3_api_gateway, start_probe, '_'))
    end).

start_quic_start_failure_test() ->
    case erlang:function_exported(cowboy, start_quic, 3) of
        false ->
            ok;
        true ->
            Cert = filename:join([code:priv_dir(pertisk_eproxy), "tls", "listener.pem"]),
            Key = filename:join([code:priv_dir(pertisk_eproxy), "tls", "listener.key"]),
            with_app_start_mocks(fun() ->
                meck:expect(pertisk_eproxy_config, get_config, fun() ->
                    (start_config())#{
                        https_port => 18443,
                        tls_cert_file => Cert,
                        tls_key_file => Key,
                        quic_enabled => true,
                        quic_port => 18444,
                        h3_api_gateway_enabled => false,
                        h3_probe_enabled => false
                    }
                end),
                meck:expect(cowboy, start_quic, fun(_, _, _) -> {error, refused} end),
                ?assertMatch({ok, _}, pertisk_eproxy_app:start(normal, [])),
                ?assertEqual(1, meck:num_calls(cowboy, start_quic, '_'))
            end)
    end.

start_custom_listener_acceptors_test() ->
    with_app_start_mocks(fun() ->
        meck:expect(pertisk_eproxy_config, get_config, fun() ->
            (start_config())#{
                http_num_acceptors => 8,
                https_num_acceptors => 8,
                management_num_acceptors => 4,
                quic_num_acceptors => 6
            }
        end),
        ?assertMatch({ok, _}, pertisk_eproxy_app:start(normal, [])),
        ?assert(meck:num_calls(cowboy, start_clear, '_') >= 3)
    end).

start_https_port_zero_disabled_test() ->
    with_app_start_mocks(fun() ->
        Cert = filename:join([code:priv_dir(pertisk_eproxy), "tls", "listener.pem"]),
        Key = filename:join([code:priv_dir(pertisk_eproxy), "tls", "listener.key"]),
        meck:expect(pertisk_eproxy_config, get_config, fun() ->
            (start_config())#{
                https_port => 0,
                tls_cert_file => Cert,
                tls_key_file => Key
            }
        end),
        ?assertMatch({ok, _}, pertisk_eproxy_app:start(normal, [])),
        ?assertEqual(0, meck:num_calls(cowboy, start_tls, '_'))
    end).

start_generate_fake_tls_openssl_failure_test() ->
    with_app_start_mocks(fun() ->
        DataDir = filename:join([
            os:getenv("TMPDIR", "/tmp"),
            "pertisk-app-tls-fail-" ++ integer_to_list(erlang:unique_integer([positive]))
        ]),
        ok = file:make_dir(DataDir),
        meck:expect(pertisk_eproxy_config, data_dir, fun() -> DataDir end),
        meck:expect(pertisk_eproxy_shell, openssl_executable, fun() -> {ok, "false"} end),
        meck:expect(pertisk_eproxy_shell, os_cmd, fun(_) -> <<"openssl failed">> end),
        try
            ?assertMatch({ok, _}, pertisk_eproxy_app:start(normal, []))
        after
            _ = os:cmd("rm -rf " ++ DataDir)
        end
    end).

reload_proxy_tls_ingress_sni_hosts_test() ->
    Cert = filename:join([code:priv_dir(pertisk_eproxy), "tls", "listener.pem"]),
    Key = filename:join([code:priv_dir(pertisk_eproxy), "tls", "listener.key"]),
    IngressCert = filename:join([code:priv_dir(pertisk_eproxy), "tls", "listener.pem"]),
    IngressKey = filename:join([code:priv_dir(pertisk_eproxy), "tls", "listener.key"]),
    with_app_reload_mocks(fun() ->
        meck:expect(pertisk_ingress_env, enabled, fun() -> true end),
        meck:new(pertisk_ingress_tls, [unstick, no_link, no_passthrough_cover]),
        meck:expect(pertisk_ingress_tls, paths_for_host, fun(H) ->
            case H of
                "ingress.example.com" -> {ok, {IngressCert, IngressKey}};
                _ -> error
            end
        end),
        meck:expect(pertisk_eproxy_config, get_config, fun() ->
            (reload_config())#{
                https_port => 18443,
                tls_cert_file => Cert,
                tls_key_file => Key,
                sites => [
                    #{
                        host => <<"ingress.example.com">>,
                        backend => <<"web">>,
                        routes => []
                    }
                ]
            }
        end),
        try
            ?assertEqual(ok, pertisk_eproxy_app:reload_proxy_tls_listeners()),
            ?assert(meck:num_calls(cowboy, start_tls, '_') >= 1)
        after
            pertisk_eproxy_test_helpers:unload_mocks([pertisk_ingress_tls])
        end
    end).

reload_proxy_tls_wildcard_sni_test() ->
    DbPath = pertisk_eproxy_test_helpers:tmp_db(),
    file:delete(DbPath),
    application:set_env(pertisk_eproxy, db_file, DbPath),
    ?assertMatch({ok, _}, pertisk_eproxy_db:init(DbPath)),
    TmpDir = filename:join([
        os:getenv("TMPDIR", "/tmp"),
        "pertisk-app-wc-" ++ integer_to_list(erlang:unique_integer([positive]))
    ]),
    ok = file:make_dir(TmpDir),
    {CertFile, KeyFile} = generate_wildcard_cert_files(TmpDir),
    {ok, CertId} = pertisk_eproxy_db:insert_certificate_pem(DbPath, <<"wc-cert">>, CertFile, KeyFile),
    try
        with_app_reload_mocks(fun() ->
            meck:expect(pertisk_eproxy_config, get_config, fun() ->
                (reload_config())#{
                    https_port => 18443,
                    tls_cert_file => CertFile,
                    tls_key_file => KeyFile,
                    sites => [
                        #{
                            host => <<"*.wc.example.com">>,
                            backend => <<"web">>,
                            certificate => integer_to_binary(CertId),
                            routes => []
                        },
                        #{
                            host => <<"admin.wc.example.com">>,
                            backend => <<"web">>,
                            routes => []
                        }
                    ]
                }
            end),
            meck:expect(pertisk_eproxy_config, db_file, fun() -> DbPath end),
            ?assertEqual(ok, pertisk_eproxy_app:reload_proxy_tls_listeners()),
            ?assert(meck:num_calls(cowboy, start_tls, '_') >= 1)
        end)
    after
        _ = os:cmd("rm -rf " ++ TmpDir),
        file:delete(DbPath)
    end.

generate_wildcard_cert_files(Dir) ->
    CertFile = filename:join(Dir, "cert.pem"),
    KeyFile = filename:join(Dir, "key.pem"),
    HostStr = "*.wc.example.com",
    Openssl = os:find_executable("openssl"),
    ?assertNotEqual(false, Openssl),
    Subject = shell_quote("/CN=" ++ HostStr),
    SubjectAltName = shell_quote("subjectAltName=DNS:" ++ HostStr),
    Cmd = Openssl ++ " req -x509 -newkey rsa:2048 -nodes -days 1 "
        "-subj " ++ Subject ++ " "
        "-addext " ++ SubjectAltName ++ " "
        "-keyout " ++ shell_quote(KeyFile) ++ " -out " ++ shell_quote(CertFile) ++ " 2>&1",
    Output = os:cmd(Cmd),
    case {filelib:is_regular(CertFile), filelib:is_regular(KeyFile)} of
        {true, true} ->
            {CertFile, KeyFile};
        Actual ->
            erlang:error({openssl_cert_generation_failed, Actual, Output})
    end.

shell_quote(Path) when is_binary(Path) ->
    shell_quote(binary_to_list(Path));
shell_quote(Path) when is_list(Path) ->
    [$' | shell_quote_1(Path)] ++ "'".

shell_quote_1([]) ->
    [];
shell_quote_1([$' | Rest]) ->
    "'\\''" ++ shell_quote_1(Rest);
shell_quote_1([C | Rest]) ->
    [C | shell_quote_1(Rest)].
