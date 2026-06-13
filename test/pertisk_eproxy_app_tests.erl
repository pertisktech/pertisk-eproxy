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
    lists:foreach(
        fun(Mod) ->
            case lists:member(Mod, meck:mocked()) of
                true -> pertisk_eproxy_test_helpers:unload_mocks([Mod]);
                false -> ok
            end
        end,
        Mods
    ).

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
    meck:new(cowboy, [unstick]),
    meck:new(pertisk_eproxy_config, [unstick, passthrough]),
    meck:new(pertisk_eproxy_h3_api_gateway, [unstick]),
    meck:new(pertisk_ingress_env, [unstick]),
    meck:new(pertisk_eproxy_tls_paths, [passthrough]),
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
        pertisk_eproxy_shell, pertisk_eproxy_auth0, pertisk_eproxy_h3_api_gateway
    ]),
    meck:new(cowboy, [unstick]),
    meck:new(pertisk_eproxy_config, [unstick, passthrough]),
    meck:new(pertisk_eproxy_metrics, [unstick]),
    meck:new(pertisk_eproxy_admin_management_snapshot, [unstick]),
    meck:new(pertisk_eproxy_sup, [unstick]),
    meck:new(pertisk_ingress_env, [unstick]),
    meck:new(pertisk_eproxy_db, [passthrough]),
    meck:new(pertisk_eproxy_shell, [unstick]),
    meck:new(pertisk_eproxy_auth0, [unstick]),
    meck:new(pertisk_eproxy_h3_api_gateway, [unstick]),
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
            pertisk_eproxy_shell, pertisk_eproxy_auth0, pertisk_eproxy_h3_api_gateway
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
        meck:new(pertisk_eproxy_env_auth, [unstick]),
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