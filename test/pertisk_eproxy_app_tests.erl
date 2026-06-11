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
                true -> meck:unload(Mod);
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
    meck:new(pertisk_eproxy_tls_paths, [unstick]),
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