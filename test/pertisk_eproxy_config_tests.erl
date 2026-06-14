-module(pertisk_eproxy_config_tests).

-include_lib("eunit/include/eunit.hrl").

%% Helper: create a basic config JSON map
basic_config() ->
    #{
        <<"mode">> => <<"proxy">>,
        <<"http_addr">> => <<"0.0.0.0">>,
        <<"http_port">> => 80
    }.

%% Helper: merge extra fields into a base config
with(Base, KVList) ->
    lists:foldl(fun({K, V}, Acc) -> Acc#{K => V} end, Base, KVList).

%% ---------------------------------------------------------------------------
%% Mode tests
%% ---------------------------------------------------------------------------

mode_proxy_test() ->
    C = pertisk_eproxy_config:json_to_config_pub(#{<<"mode">> => <<"proxy">>}),
    ?assertEqual(proxy, maps:get(mode, C)).

mode_ingress_test() ->
    C = pertisk_eproxy_config:json_to_config_pub(#{<<"mode">> => <<"ingress">>}),
    ?assertEqual(ingress, maps:get(mode, C)).

mode_invalid_returns_proxy_test() ->
    C = pertisk_eproxy_config:json_to_config_pub(#{<<"mode">> => <<"invalid">>}),
    ?assertEqual(proxy, maps:get(mode, C)).

mode_proxy_admin_test() ->
    C = pertisk_eproxy_config:json_to_config_pub(#{<<"mode">> => <<"proxy_admin">>}),
    ?assertEqual(proxy, maps:get(mode, C)).

%% ---------------------------------------------------------------------------
%% HTTP listener settings
%% ---------------------------------------------------------------------------

http_addr_default_test() ->
    C = pertisk_eproxy_config:json_to_config_pub(#{}),
    ?assertEqual({0,0,0,0}, maps:get(http_addr, C)).

http_addr_custom_test() ->
    C = pertisk_eproxy_config:json_to_config_pub(#{<<"http_addr">> => <<"127.0.0.1">>}),
    ?assertEqual({127,0,0,1}, maps:get(http_addr, C)).

http_port_default_test() ->
    C = pertisk_eproxy_config:json_to_config_pub(#{}),
    ?assertEqual(80, maps:get(http_port, C)).

http_port_custom_test() ->
    C = pertisk_eproxy_config:json_to_config_pub(#{<<"http_port">> => 8080}),
    ?assertEqual(8080, maps:get(http_port, C)).

management_port_default_test() ->
    C = pertisk_eproxy_config:json_to_config_pub(#{}),
    ?assertEqual(9080, maps:get(management_port, C)).

https_port_not_set_by_default_test() ->
    C = pertisk_eproxy_config:json_to_config_pub(#{}),
    ?assertEqual(false, maps:is_key(https_port, C)).

https_port_set_test() ->
    C = pertisk_eproxy_config:json_to_config_pub(#{<<"https_port">> => 443}),
    ?assertEqual(443, maps:get(https_port, C)).

%% ---------------------------------------------------------------------------
%% Quic/H3 settings
%% ---------------------------------------------------------------------------

quic_enabled_test() ->
    C = pertisk_eproxy_config:json_to_config_pub(#{<<"quic_enabled">> => true}),
    ?assertEqual(true, maps:get(quic_enabled, C)).

quic_port_test() ->
    C = pertisk_eproxy_config:json_to_config_pub(#{<<"quic_port">> => 4433}),
    ?assertEqual(4433, maps:get(quic_port, C)).

h3_udp_bind_dual_stack_test() ->
    C = pertisk_eproxy_config:json_to_config_pub(#{<<"h3_udp_bind">> => <<"dual_stack">>}),
    ?assertEqual(dual_stack, maps:get(h3_udp_bind, C)).

h3_udp_bind_split_test() ->
    C = pertisk_eproxy_config:json_to_config_pub(#{<<"h3_udp_bind">> => <<"split">>}),
    ?assertEqual(split, maps:get(h3_udp_bind, C)).

h3_udp_bind_invalid_returns_dual_stack_test() ->
    C = pertisk_eproxy_config:json_to_config_pub(#{<<"h3_udp_bind">> => <<"unknown">>}),
    ?assertEqual(dual_stack, maps:get(h3_udp_bind, C)).

h3_qpack_static_default_test() ->
    C = pertisk_eproxy_config:json_to_config_pub(#{}),
    ?assertEqual(true, maps:get(h3_qpack_static, C)).

%% ---------------------------------------------------------------------------
%% Sites
%% ---------------------------------------------------------------------------

sites_single_test() ->
    C = pertisk_eproxy_config:json_to_config_pub(#{
        <<"sites">> => [#{
            <<"host">> => <<"example.com">>,
            <<"backend">> => <<"web">>
        }]
    }),
    Sites = maps:get(sites, C),
    ?assertEqual(1, length(Sites)),
    [Site] = Sites,
    ?assertEqual(<<"example.com">>, maps:get(host, Site)),
    ?assertEqual(<<"web">>, maps:get(backend, Site)).

sites_with_routes_test() ->
    C = pertisk_eproxy_config:json_to_config_pub(#{
        <<"sites">> => [#{
            <<"host">> => <<"example.com">>,
            <<"backend">> => <<"web">>,
            <<"routes">> => [#{
                <<"path">> => <<"/api">>,
                <<"path_type">> => <<"prefix">>
            }]
        }]
    }),
    Sites = maps:get(sites, C),
    [Site] = Sites,
    Routes = maps:get(routes, Site),
    ?assertEqual(1, length(Routes)).

sites_route_exact_test() ->
    C = pertisk_eproxy_config:json_to_config_pub(#{
        <<"sites">> => [#{
            <<"host">> => <<"example.com">>,
            <<"backend">> => <<"web">>,
            <<"routes">> => [#{
                <<"path">> => <<"/status">>,
                <<"path_type">> => <<"exact">>
            }]
        }]
    }),
    [#{routes := [Route]}] = maps:get(sites, C),
    ?assertEqual(exact, maps:get(path_type, Route)).

sites_route_with_rewrite_test() ->
    C = pertisk_eproxy_config:json_to_config_pub(#{
        <<"sites">> => [#{
            <<"host">> => <<"example.com">>,
            <<"backend">> => <<"web">>,
            <<"routes">> => [#{
                <<"path">> => <<"/old">>,
                <<"rewrite">> => <<"/new">>
            }]
        }]
    }),
    [#{routes := [Route]}] = maps:get(sites, C),
    ?assertEqual("/new", maps:get(rewrite, Route)).

sites_with_certificate_test() ->
    C = pertisk_eproxy_config:json_to_config_pub(#{
        <<"sites">> => [#{
            <<"host">> => <<"example.com">>,
            <<"backend">> => <<"web">>,
            <<"certificate">> => <<"my-cert">>
        }]
    }),
    [#{certificate := Cert}] = maps:get(sites, C),
    ?assertEqual("my-cert", Cert).

sites_with_advertise_http3_test() ->
    C = pertisk_eproxy_config:json_to_config_pub(#{
        <<"sites">> => [#{
            <<"host">> => <<"example.com">>,
            <<"backend">> => <<"web">>,
            <<"advertise_http3">> => true
        }]
    }),
    [#{advertise_http3 := H3}] = maps:get(sites, C),
    ?assertEqual(true, H3).

sites_challenge_type_http01_test() ->
    C = pertisk_eproxy_config:json_to_config_pub(#{
        <<"sites">> => [#{
            <<"host">> => <<"example.com">>,
            <<"backend">> => <<"web">>,
            <<"challenge_type">> => <<"http-01">>
        }]
    }),
    [#{challenge_type := CT}] = maps:get(sites, C),
    ?assertEqual("http-01", CT).

sites_challenge_type_dns01_test() ->
    C = pertisk_eproxy_config:json_to_config_pub(#{
        <<"sites">> => [#{
            <<"host">> => <<"example.com">>,
            <<"backend">> => <<"web">>,
            <<"challenge_type">> => <<"dns-01">>
        }]
    }),
    [#{challenge_type := CT}] = maps:get(sites, C),
    ?assertEqual("dns-01", CT).

%% ---------------------------------------------------------------------------
%% Backends
%% ---------------------------------------------------------------------------

backend_round_robin_test() ->
    C = pertisk_eproxy_config:json_to_config_pub(#{
        <<"backends">> => [#{
            <<"name">> => <<"web">>,
            <<"algorithm">> => <<"round_robin">>,
            <<"upstreams">> => [
                #{<<"addr">> => <<"10.0.0.1:8080">>},
                #{<<"addr">> => <<"10.0.0.2:8080">>}
            ]
        }]
    }),
    Backends = maps:get(backends, C),
    ?assertEqual(1, length(Backends)),
    [B] = Backends,
    ?assertEqual(<<"web">>, maps:get(name, B)),
    ?assertEqual(round_robin, maps:get(algorithm, B)),
    ?assertEqual(2, length(maps:get(upstreams, B))).

backend_least_connections_test() ->
    C = pertisk_eproxy_config:json_to_config_pub(#{
        <<"backends">> => [#{
            <<"name">> => <<"api">>,
            <<"algorithm">> => <<"least_connections">>,
            <<"upstreams">> => [
                #{<<"addr">> => <<"10.0.0.1:8080">>}
            ]
        }]
    }),
    [B] = maps:get(backends, C),
    ?assertEqual(least_connections, maps:get(algorithm, B)).

backend_ip_hash_test() ->
    C = pertisk_eproxy_config:json_to_config_pub(#{
        <<"backends">> => [#{
            <<"name">> => <<"sticky">>,
            <<"algorithm">> => <<"ip_hash">>,
            <<"upstreams">> => [
                #{<<"addr">> => <<"10.0.0.1:8080">>}
            ]
        }]
    }),
    [B] = maps:get(backends, C),
    ?assertEqual(ip_hash, maps:get(algorithm, B)).

backend_invalid_algorithm_returns_round_robin_test() ->
    C = pertisk_eproxy_config:json_to_config_pub(#{
        <<"backends">> => [#{
            <<"name">> => <<"web">>,
            <<"algorithm">> => <<"random">>,
            <<"upstreams">> => [
                #{<<"addr">> => <<"10.0.0.1:8080">>}
            ]
        }]
    }),
    [B] = maps:get(backends, C),
    ?assertEqual(round_robin, maps:get(algorithm, B)).

backend_health_settings_test() ->
    C = pertisk_eproxy_config:json_to_config_pub(#{
        <<"backends">> => [#{
            <<"name">> => <<"web">>,
            <<"health_path">> => <<"/healthz">>,
            <<"health_interval_secs">> => 15,
            <<"upstreams">> => [
                #{<<"addr">> => <<"10.0.0.1:8080">>}
            ]
        }]
    }),
    [B] = maps:get(backends, C),
    ?assertEqual("/healthz", maps:get(health_path, B)),
    ?assertEqual(15, maps:get(health_interval_secs, B)).

backend_no_upstreams_test() ->
    C = pertisk_eproxy_config:json_to_config_pub(#{
        <<"backends">> => [#{
            <<"name">> => <<"empty">>
        }]
    }),
    [B] = maps:get(backends, C),
    ?assertEqual([], maps:get(upstreams, B)).

%% ---------------------------------------------------------------------------
%% DNS providers
%% ---------------------------------------------------------------------------

dns_providers_legacy_string_test() ->
    C = pertisk_eproxy_config:json_to_config_pub(#{
        <<"dns_providers">> => [<<"cloudflare-key1">>]
    }),
    Providers = maps:get(dns_providers, C),
    ?assertEqual(1, length(Providers)),
    [P] = Providers,
    ?assertEqual("cloudflare-key1", maps:get(name, P)).

dns_providers_object_test() ->
    C = pertisk_eproxy_config:json_to_config_pub(#{
        <<"dns_providers">> => [#{
            <<"name">> => <<"cf">>,
            <<"provider_type">> => <<"cloudflare">>,
            <<"credentials">> => #{
                <<"api_token">> => <<"secret">>
            }
        }]
    }),
    Providers = maps:get(dns_providers, C),
    ?assertEqual(1, length(Providers)),
    [P] = Providers,
    ?assertEqual("cf", maps:get(name, P)),
    ?assertEqual("cloudflare", maps:get(provider_type, P)).

%% ---------------------------------------------------------------------------
%% Certificates
%% ---------------------------------------------------------------------------

certificates_test() ->
    C = pertisk_eproxy_config:json_to_config_pub(#{
        <<"certificates">> => [<<"cert-1">>, <<"cert-2">>, <<"my-site-cert">>]
    }),
    Certs = maps:get(certificates, C),
    ?assertEqual(3, length(Certs)),
    ?assertEqual("cert-1", lists:nth(1, Certs)),
    ?assertEqual("my-site-cert", lists:nth(3, Certs)).

certificates_digits_only_excluded_test() ->
    C = pertisk_eproxy_config:json_to_config_pub(#{
        <<"certificates">> => [<<"12345">>, <<"name-1">>]
    }),
    Certs = maps:get(certificates, C),
    ?assertEqual(1, length(Certs)),
    ?assertEqual("name-1", hd(Certs)).

certificates_empty_string_excluded_test() ->
    C = pertisk_eproxy_config:json_to_config_pub(#{
        <<"certificates">> => [<<"">>, <<"valid">>]
    }),
    Certs = maps:get(certificates, C),
    ?assertEqual(1, length(Certs)),
    ?assertEqual("valid", hd(Certs)).

%% ---------------------------------------------------------------------------
%% Management TLS
%% ---------------------------------------------------------------------------

management_tls_enabled_test() ->
    C = pertisk_eproxy_config:json_to_config_pub(#{<<"management_tls_enabled">> => true}),
    ?assertEqual(true, maps:get(management_tls_enabled, C)).

management_tls_disabled_default_test() ->
    C = pertisk_eproxy_config:json_to_config_pub(#{}),
    ?assertEqual(false, maps:get(management_tls_enabled, C)).

%% ---------------------------------------------------------------------------
%% Metrics
%% ---------------------------------------------------------------------------

metrics_port_default_test() ->
    C = pertisk_eproxy_config:json_to_config_pub(#{}),
    ?assertEqual(9090, maps:get(metrics_port, C)).

metrics_port_custom_test() ->
    C = pertisk_eproxy_config:json_to_config_pub(#{<<"metrics_port">> => 9191}),
    ?assertEqual(9191, maps:get(metrics_port, C)).

%% ---------------------------------------------------------------------------
%% Undefined values are filtered
%% ---------------------------------------------------------------------------

undefined_values_filtered_test() ->
    C = pertisk_eproxy_config:json_to_config_pub(#{}),
    ?assertEqual(false, maps:is_key(https_port, C)),
    ?assertEqual(false, maps:is_key(quic_port, C)).

%% ---------------------------------------------------------------------------
%% Edge cases: null values
%% ---------------------------------------------------------------------------

null_values_pass_through_unchanged_test() ->
    %% null in JSON is the Erlang atom null, not undefined.
    %% The config module filters undefined values but null passes through as-is.
    C = pertisk_eproxy_config:json_to_config_pub(#{
        <<"management_port">> => null,
        <<"http_port">> => null
    }),
    ?assertEqual(null, maps:get(management_port, C)),
    ?assertEqual(null, maps:get(http_port, C)).

%% ---------------------------------------------------------------------------
%% TLS paths and listener options
%% ---------------------------------------------------------------------------

tls_paths_parsed_test() ->
    C = pertisk_eproxy_config:json_to_config_pub(#{
        <<"tls_cert_file">> => <<"/etc/ssl/cert.pem">>,
        <<"tls_key_file">> => <<"/etc/ssl/key.pem">>
    }),
    ?assertEqual("/etc/ssl/cert.pem", maps:get(tls_cert_file, C)),
    ?assertEqual("/etc/ssl/key.pem", maps:get(tls_key_file, C)).

tls_redacted_cert_path_filtered_test() ->
    C = pertisk_eproxy_config:json_to_config_pub(#{
        <<"tls_cert_file">> => <<"[redacted]">>,
        <<"tls_key_file">> => <<"/etc/ssl/key.pem">>
    }),
    ?assertEqual(false, maps:is_key(tls_cert_file, C)),
    ?assertEqual("/etc/ssl/key.pem", maps:get(tls_key_file, C)).

log_level_parsed_test() ->
    C = pertisk_eproxy_config:json_to_config_pub(#{<<"log_level">> => <<"warning">>}),
    ?assertEqual(warn, maps:get(log_level, C)).

sse_early_flush_default_true_test() ->
    C = pertisk_eproxy_config:json_to_config_pub(#{}),
    ?assertEqual(true, maps:get(sse_early_flush_enabled, C)).

sse_early_flush_disabled_test() ->
    C = pertisk_eproxy_config:json_to_config_pub(#{<<"sse_early_flush_enabled">> => false}),
    ?assertEqual(false, maps:get(sse_early_flush_enabled, C)).

health_access_log_test() ->
    C = pertisk_eproxy_config:json_to_config_pub(#{
        <<"health_access_log">> => true,
        <<"health_access_log_sample">> => 50
    }),
    ?assertEqual(true, maps:get(health_access_log, C)),
    ?assertEqual(50, maps:get(health_access_log_sample, C)).

sites_wildcard_and_dns_provider_test() ->
    C = pertisk_eproxy_config:json_to_config_pub(#{
        <<"sites">> => [#{
            <<"host">> => <<"*.example.com">>,
            <<"backend">> => <<"web">>,
            <<"wildcard">> => true,
            <<"dns_provider">> => <<"cf">>,
            <<"acme_wildcard_base">> => <<"*.example.com">>,
            <<"acme_contact_email">> => <<"ops@example.com">>
        }]
    }),
    [#{wildcard := true, dns_provider := "cf"}] = maps:get(sites, C).

dns_providers_skips_invalid_entries_test() ->
    C = pertisk_eproxy_config:json_to_config_pub(#{
        <<"dns_providers">> => [
            #{<<"provider_type">> => <<"label">>},
            <<"valid-legacy">>
        ]
    }),
    Providers = maps:get(dns_providers, C),
    ?assertEqual(1, length(Providers)),
    ?assertEqual("valid-legacy", maps:get(name, hd(Providers))).

metrics_enabled_from_json_test() ->
    C = pertisk_eproxy_config:json_to_config_pub(#{<<"metrics_enabled">> => false}),
    ?assertEqual(false, maps:get(metrics_enabled, C)).

metrics_addr_parsed_test() ->
    C = pertisk_eproxy_config:json_to_config_pub(#{<<"metrics_addr">> => <<"127.0.0.1">>}),
    ?assertEqual({127, 0, 0, 1}, maps:get(metrics_addr, C)).

upstream_pool_settings_test() ->
    C = pertisk_eproxy_config:json_to_config_pub(#{
        <<"upstream_pool_size">> => 32,
        <<"upstream_pool_idle_timeout_secs">> => 120
    }),
    ?assertEqual(32, maps:get(upstream_pool_size, C)),
    ?assertEqual(120, maps:get(upstream_pool_idle_timeout_secs, C)).

h3_feature_flags_test() ->
    C = pertisk_eproxy_config:json_to_config_pub(#{
        <<"h3_api_gateway_enabled">> => true,
        <<"h3_probe_enabled">> => false,
        <<"h3_probe_port">> => 4433
    }),
    ?assertEqual(true, maps:get(h3_api_gateway_enabled, C)),
    ?assertEqual(false, maps:get(h3_probe_enabled, C)),
    ?assertEqual(4433, maps:get(h3_probe_port, C)).

acceptor_and_connection_limits_test() ->
    C = pertisk_eproxy_config:json_to_config_pub(#{
        <<"http_num_acceptors">> => 50,
        <<"https_num_acceptors">> => 25,
        <<"quic_num_acceptors">> => 8,
        <<"proxy_max_connections">> => 4096,
        <<"management_num_acceptors">> => 4,
        <<"management_max_connections">> => 512,
        <<"metrics_max_connections">> => 64
    }),
    ?assertEqual(50, maps:get(http_num_acceptors, C)),
    ?assertEqual(25, maps:get(https_num_acceptors, C)),
    ?assertEqual(8, maps:get(quic_num_acceptors, C)),
    ?assertEqual(4096, maps:get(proxy_max_connections, C)),
    ?assertEqual(4, maps:get(management_num_acceptors, C)),
    ?assertEqual(512, maps:get(management_max_connections, C)),
    ?assertEqual(64, maps:get(metrics_max_connections, C)).

alt_svc_and_tls_http2_test() ->
    C = pertisk_eproxy_config:json_to_config_pub(#{
        <<"alt_svc_port">> => 4433,
        <<"tls_http2_enabled">> => false
    }),
    ?assertEqual(4433, maps:get(alt_svc_port, C)),
    ?assertEqual(false, maps:get(tls_http2_enabled, C)).

h3_quic_tuning_test() ->
    C = pertisk_eproxy_config:json_to_config_pub(#{
        <<"h3_idle_timeout_secs">> => 120,
        <<"h3_keepalive_interval_secs">> => 15,
        <<"h3_quic_pool_size">> => 16,
        <<"h3_max_udp_payload_size">> => 1400,
        <<"h3_pmtu_enabled">> => false,
        <<"h3_max_streams">> => 1024,
        <<"h3_stream_receive_window">> => 1048576,
        <<"h3_conn_receive_window">> => 8388608
    }),
    ?assertEqual(120, maps:get(h3_idle_timeout_secs, C)),
    ?assertEqual(15, maps:get(h3_keepalive_interval_secs, C)),
    ?assertEqual(16, maps:get(h3_quic_pool_size, C)),
    ?assertEqual(1400, maps:get(h3_max_udp_payload_size, C)),
    ?assertEqual(false, maps:get(h3_pmtu_enabled, C)),
    ?assertEqual(1024, maps:get(h3_max_streams, C)),
    ?assertEqual(1048576, maps:get(h3_stream_receive_window, C)),
    ?assertEqual(8388608, maps:get(h3_conn_receive_window, C)).

management_addr_parsed_test() ->
    C = pertisk_eproxy_config:json_to_config_pub(#{<<"management_addr">> => <<"127.0.0.1">>}),
    ?assertEqual({127, 0, 0, 1}, maps:get(management_addr, C)).

timeout_and_pool_settings_test() ->
    C = pertisk_eproxy_config:json_to_config_pub(#{
        <<"downstream_idle_timeout_ms">> => 60000,
        <<"management_idle_timeout_ms">> => 120000,
        <<"upstream_request_timeout_ms">> => 90000,
        <<"upstream_stream_request_timeout_ms">> => 45000,
        <<"health_cache_refresh_ms">> => 5000,
        <<"sse_initial_headers_timeout_ms">> => 3000,
        <<"event_stream_heartbeat_ms">> => 20000
    }),
    ?assertEqual(60000, maps:get(downstream_idle_timeout_ms, C)),
    ?assertEqual(120000, maps:get(management_idle_timeout_ms, C)),
    ?assertEqual(90000, maps:get(upstream_request_timeout_ms, C)),
    ?assertEqual(45000, maps:get(upstream_stream_request_timeout_ms, C)),
    ?assertEqual(5000, maps:get(health_cache_refresh_ms, C)),
    ?assertEqual(3000, maps:get(sse_initial_headers_timeout_ms, C)),
    ?assertEqual(20000, maps:get(event_stream_heartbeat_ms, C)).

proxy_access_log_test() ->
    C = pertisk_eproxy_config:json_to_config_pub(#{<<"proxy_access_log">> => false}),
    ?assertEqual(false, maps:get(proxy_access_log, C)).

sites_sse_early_flush_test() ->
    C = pertisk_eproxy_config:json_to_config_pub(#{
        <<"sites">> => [#{
            <<"host">> => <<"sse.example.com">>,
            <<"backend">> => <<"web">>,
            <<"sse_early_flush">> => false,
            <<"routes">> => [#{
                <<"path">> => <<"/events">>,
                <<"sse_early_flush">> => true
            }]
        }]
    }),
    [#{sse_early_flush := false, routes := [Route]}] = maps:get(sites, C),
    ?assertEqual(true, maps:get(sse_early_flush, Route)).

backend_upstream_weight_test() ->
    C = pertisk_eproxy_config:json_to_config_pub(#{
        <<"backends">> => [#{
            <<"name">> => <<"weighted">>,
            <<"upstreams">> => [#{<<"addr">> => <<"10.0.0.1:8080">>, <<"weight">> => 3}]
        }]
    }),
    [#{upstreams := [#{weight := 3}]}] = maps:get(backends, C).

json_as_list_null_sites_test() ->
    C = pertisk_eproxy_config:json_to_config_pub(#{<<"sites">> => null, <<"backends">> => null}),
    ?assertEqual([], maps:get(sites, C)),
    ?assertEqual([], maps:get(backends, C)).

is_management_upstream_addr_test() ->
    with_config(fun() ->
        Port = maps:get(management_port, pertisk_eproxy_config:get_config(), 9080),
        Upstream = iolist_to_binary(["127.0.0.1:", integer_to_list(Port)]),
        ?assert(pertisk_eproxy_config:is_management_upstream_addr(Upstream)),
        ?assertNot(pertisk_eproxy_config:is_management_upstream_addr(<<"127.0.0.1:8080">>))
    end).

ingress_mode_false_by_default_test() ->
    with_env("PERTISK_MODE", unset, fun() ->
        OldMode = application:get_env(pertisk_eproxy, mode),
        application:unset_env(pertisk_eproxy, mode),
        try
            with_tmp_db_config(fun() ->
                ?assertNot(pertisk_eproxy_config:ingress_mode())
            end)
        after
            case OldMode of
                {ok, V} -> application:set_env(pertisk_eproxy, mode, V);
                undefined -> ok
            end
        end
    end).

%% ---------------------------------------------------------------------------
%% Runtime API (ETS-backed gen_server)
%% ---------------------------------------------------------------------------

with_config(Fun) ->
    application:ensure_all_started(lager),
    Started = case whereis(pertisk_eproxy_config) of
        undefined ->
            {ok, _} = pertisk_eproxy_config:start_link(),
            true;
        _ ->
            false
    end,
    BaseConfig = pertisk_eproxy_config:get_config(),
    BaseSites = pertisk_eproxy_config:get_sites(),
    BaseBackends = pertisk_eproxy_config:get_backends(),
    try
        Fun()
    after
        _ = pertisk_eproxy_test_helpers:ignoring_errors(fun() -> put_config_retry(BaseConfig) end),
        pertisk_eproxy_test_helpers:ignoring_errors(fun() -> pertisk_eproxy_config:sync_ingress(BaseSites, BaseBackends) end),
        maybe_stop_config(Started)
    end.

init_tmp_db(DbPath) ->
    init_tmp_db(DbPath, 12).

put_config_retry(Config) ->
    pertisk_eproxy_test_helpers:put_config_retry(Config).

sqlite_locked_msg(Msg) when is_binary(Msg) ->
    binary:match(Msg, <<"locked">>) =/= nomatch;
sqlite_locked_msg(Msg) when is_list(Msg) ->
    string:find(Msg, "locked") =/= nomatch;
sqlite_locked_msg(_) ->
    false.

init_tmp_db(DbPath, 0) ->
    pertisk_eproxy_db:init(DbPath);
init_tmp_db(DbPath, Retries) ->
    case pertisk_eproxy_db:init(DbPath) of
        {ok, _} = Ok ->
            Ok;
        {error, {sqlite_error, Msg, _}} when Retries > 0 ->
            Locked =
                case Msg of
                    B when is_binary(B) -> binary:match(B, <<"locked">>) =/= nomatch;
                    S when is_list(S) -> string:find(S, "locked") =/= nomatch;
                    _ -> false
                end,
            case Locked of
                true ->
                    timer:sleep(50),
                    init_tmp_db(DbPath, Retries - 1);
                false ->
                    {error, {sqlite_error, Msg, locked}}
            end;
        Other ->
            Other
    end.

stop_config_if_running() ->
    case whereis(pertisk_eproxy_config) of
        undefined ->
            ok;
        Pid ->
            pertisk_eproxy_test_helpers:safe_gen_server_stop(Pid, normal, 5000),
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

with_tmp_db_config(Fun) ->
    pertisk_eproxy_test_helpers:with_db_lock(fun() ->
        DbPath = pertisk_eproxy_test_helpers:tmp_db(),
        file:delete(DbPath),
        OldDb = application:get_env(pertisk_eproxy, db_file),
        ConfigWasUp = whereis(pertisk_eproxy_config) =/= undefined,
        application:set_env(pertisk_eproxy, db_file, DbPath),
        try
            ?assertMatch({ok, _}, init_tmp_db(DbPath)),
            case ConfigWasUp of
                true ->
                    ok = pertisk_eproxy_config:reload();
                false ->
                    ok
            end,
            with_config(Fun)
        after
            case OldDb of
                {ok, V} -> application:set_env(pertisk_eproxy, db_file, V);
                undefined -> application:unset_env(pertisk_eproxy, db_file)
            end,
            file:delete(DbPath),
            case ConfigWasUp of
                true ->
                    pertisk_eproxy_test_helpers:ignoring_errors(fun() -> pertisk_eproxy_config:reload() end);
                false ->
                    stop_config_if_running()
            end
        end
    end).

maybe_stop_config(true) ->
    case whereis(pertisk_eproxy_config) of
        undefined -> ok;
        Pid -> gen_server:stop(Pid)
    end;
maybe_stop_config(_) ->
    ok.

sync_ingress_updates_sites_and_backends_test() ->
    with_config(fun() ->
        Sites = [#{host => <<"a.example">>, backend => <<"web">>, routes => []}],
        Backends = [#{
            name => <<"web">>,
            algorithm => round_robin,
            upstreams => [#{addr => <<"127.0.0.1:8080">>, weight => 1}]
        }],
        ok = pertisk_eproxy_config:sync_ingress(Sites, Backends),
        ?assertEqual(Sites, pertisk_eproxy_config:get_sites()),
        ?assertEqual(Backends, pertisk_eproxy_config:get_backends()),
        ?assertMatch({ok, _}, pertisk_eproxy_config:get_backend(<<"web">>)),
        ?assertEqual(error, pertisk_eproxy_config:get_backend(<<"missing">>)),
        Router = pertisk_eproxy_config:get_router(),
        ?assert(is_list(Router))
    end).

get_config_returns_applied_map_test() ->
    with_config(fun() ->
        C = pertisk_eproxy_config:get_config(),
        ?assert(is_map(C)),
        ?assert(maps:is_key(http_port, C) orelse maps:is_key(sites, C))
    end).

get_certificates_and_dns_providers_test() ->
    with_tmp_db_config(fun() ->
        Config = (pertisk_eproxy_config:get_config())#{
            certificates => [<<"cert-a">>],
            dns_providers => [#{name => <<"cf">>, provider_type => <<"label">>, credentials => #{}}],
            sites => [],
            backends => []
        },
        ok = put_config_retry(Config),
        ?assertEqual([<<"cert-a">>], pertisk_eproxy_config:get_certificates()),
        ?assertEqual(["cf"], pertisk_eproxy_config:get_dns_providers())
    end).

management_upstream_bin_test() ->
    with_tmp_db_config(fun() ->
        Config = (pertisk_eproxy_config:get_config())#{
            management_addr => {127, 0, 0, 1},
            management_port => 19080,
            sites => [],
            backends => [],
            certificates => [],
            dns_providers => []
        },
        ok = put_config_retry(Config),
        ?assertEqual(<<"127.0.0.1:19080">>, pertisk_eproxy_config:management_upstream_bin()),
        ?assertEqual(<<"127.0.0.1:19080">>, pertisk_eproxy_config:management_loopback_upstream_bin())
    end).

metrics_enabled_defaults_true_test() ->
    with_config(fun() ->
        ?assertEqual(true, pertisk_eproxy_config:metrics_enabled())
    end).

metrics_listen_defaults_test() ->
    with_config(fun() ->
        ?assertEqual({{0, 0, 0, 0}, 9090}, pertisk_eproxy_config:metrics_listen())
    end).

backend_is_management_only_test() ->
    with_config(fun() ->
        Mgmt = pertisk_eproxy_config:management_loopback_upstream_bin(),
        Sites = [],
        Backends = [#{
            name => <<"mgmt">>,
            algorithm => round_robin,
            upstreams => [#{addr => Mgmt, weight => 1}]
        }],
        ok = pertisk_eproxy_config:sync_ingress(Sites, Backends),
        ?assert(pertisk_eproxy_config:backend_is_management_only(<<"mgmt">>)),
        ?assertNot(pertisk_eproxy_config:backend_is_management_only(<<"other">>))
    end).

proxy_mode_default_test() ->
    with_env("PERTISK_MODE", unset, fun() ->
        OldMode = application:get_env(pertisk_eproxy, mode),
        application:unset_env(pertisk_eproxy, mode),
        try
            with_tmp_db_config(fun() ->
                ?assert(pertisk_eproxy_config:proxy_mode())
            end)
        after
            case OldMode of
                {ok, V} -> application:set_env(pertisk_eproxy, mode, V);
                undefined -> ok
            end
        end
    end).

db_file_and_data_dir_test() ->
    with_config(fun() ->
        Db = pertisk_eproxy_config:db_file(),
        ?assert(is_list(Db)),
        DataDir = pertisk_eproxy_config:data_dir(),
        ?assertEqual(filename:dirname(Db), DataDir)
    end).

put_config_with_tmp_db_test() ->
    with_tmp_db_config(fun() ->
        DbPath = pertisk_eproxy_config:db_file(),
        Config = (pertisk_eproxy_config:get_config())#{
            sites => [],
            backends => [],
            certificates => [],
            dns_providers => []
        },
        ?assertEqual(ok, put_config_retry(Config)),
        ?assertMatch({ok, _}, pertisk_eproxy_db:get_runtime_config(DbPath))
    end).

put_config_persists_runtime_config_test() ->
    with_tmp_db_config(fun() ->
        DbPath = pertisk_eproxy_config:db_file(),
        Config = (pertisk_eproxy_config:get_config())#{
            sites => [#{host => <<"x.example">>, backend => <<"web">>, routes => []}],
            backends => [#{
                name => <<"web">>,
                algorithm => round_robin,
                upstreams => [#{addr => <<"127.0.0.1:1">>, weight => 1}]
            }],
            certificates => [],
            dns_providers => [#{name => <<"cf">>, provider_type => <<"label">>, credentials => #{}}]
        },
        ?assertEqual(ok, put_config_retry(Config)),
        {ok, Stored} = pertisk_eproxy_db:get_runtime_config(DbPath),
        ?assertEqual(1, length(maps:get(sites, Stored))),
        ?assertMatch({ok, [_]}, pertisk_eproxy_db:list_dns_providers(DbPath))
    end).

put_config_rejected_in_ingress_env_test() ->
    with_config(fun() ->
        with_ingress_env(fun() ->
            ?assertEqual(
                {error, ingress_manifest_mode},
                pertisk_eproxy_config:put_config(pertisk_eproxy_config:get_config())
            )
        end)
    end).

put_config_unknown_certificate_rejected_test() ->
    with_tmp_db_config(fun() ->
        Config = (pertisk_eproxy_config:get_config())#{
            sites => [#{
                host => <<"tls.example.com">>,
                backend => <<"web">>,
                certificate => <<"missing-cert">>,
                routes => []
            }],
            backends => [#{
                name => <<"web">>,
                algorithm => round_robin,
                upstreams => [#{addr => <<"127.0.0.1:8080">>, weight => 1}]
            }],
            certificates => [],
            dns_providers => []
        },
        ?assertMatch(
            {error, {tls_validation_unknown_certificate, _, _}},
            pertisk_eproxy_config:put_config(Config)
        )
    end).

reload_in_ingress_mode_triggers_reconcile_test() ->
    with_config(fun() ->
        with_ingress_env(fun() ->
            case whereis(pertisk_ingress_watcher) of
                undefined -> ok;
                Pid -> pertisk_eproxy_test_helpers:safe_gen_server_stop(Pid)
            end,
            ?assertEqual(ok, pertisk_eproxy_config:reload())
        end)
    end).

reload_in_proxy_mode_ok_test() ->
    with_tmp_db_config(fun() ->
        ?assertEqual(ok, pertisk_eproxy_config:reload())
    end).

ingress_mode_from_parsed_config_test() ->
    C = pertisk_eproxy_config:json_to_config_pub(#{<<"mode">> => <<"ingress">>}),
    ?assertEqual(ingress, maps:get(mode, C)).

ingress_mode_from_env_test() ->
    with_config(fun() ->
        with_ingress_env(fun() ->
            ?assert(pertisk_eproxy_config:ingress_mode()),
            ?assertNot(pertisk_eproxy_config:proxy_mode())
        end)
    end).

management_port_custom_test() ->
    C = pertisk_eproxy_config:json_to_config_pub(#{<<"management_port">> => 19080}),
    ?assertEqual(19080, maps:get(management_port, C)).

h3_qpack_static_disabled_test() ->
    C = pertisk_eproxy_config:json_to_config_pub(#{<<"h3_qpack_static">> => false}),
    ?assertEqual(false, maps:get(h3_qpack_static, C)).

quic_enabled_default_false_test() ->
    C = pertisk_eproxy_config:json_to_config_pub(#{}),
    ?assertEqual(false, maps:get(quic_enabled, C)).

http_addr_invalid_falls_back_test() ->
    C = pertisk_eproxy_config:json_to_config_pub(#{<<"http_addr">> => <<"not-an-ip">>}),
    ?assertEqual({0, 0, 0, 0}, maps:get(http_addr, C)).

log_level_invalid_filtered_test() ->
    C = pertisk_eproxy_config:json_to_config_pub(#{<<"log_level">> => <<"verbose">>}),
    ?assertEqual(false, maps:is_key(log_level, C)).

log_level_error_parsed_test() ->
    C = pertisk_eproxy_config:json_to_config_pub(#{<<"log_level">> => <<"error">>}),
    ?assertEqual(error, maps:get(log_level, C)).

sites_skip_non_map_entries_test() ->
    C = pertisk_eproxy_config:json_to_config_pub(#{
        <<"sites">> => [null, #{<<"host">> => <<"ok.example">>, <<"backend">> => <<"web">>}]
    }),
    ?assertEqual(1, length(maps:get(sites, C))).

backends_skip_non_map_entries_test() ->
    C = pertisk_eproxy_config:json_to_config_pub(#{
        <<"backends">> => [
            <<"ignored">>,
            #{<<"name">> => <<"web">>, <<"upstreams">> => [#{<<"addr">> => <<"10.0.0.1:8080">>}]}
        ]
    }),
    ?assertEqual(1, length(maps:get(backends, C))).

route_default_path_test() ->
    C = pertisk_eproxy_config:json_to_config_pub(#{
        <<"sites">> => [#{
            <<"host">> => <<"example.com">>,
            <<"backend">> => <<"web">>,
            <<"routes">> => [#{}]
        }]
    }),
    [#{routes := [Route]}] = maps:get(sites, C),
    ?assertEqual(<<"/">>, maps:get(path, Route)).

sites_invalid_challenge_type_filtered_test() ->
    C = pertisk_eproxy_config:json_to_config_pub(#{
        <<"sites">> => [#{
            <<"host">> => <<"example.com">>,
            <<"backend">> => <<"web">>,
            <<"challenge_type">> => <<"tls-alpn-01">>
        }]
    }),
    [#{challenge_type := undefined}] = maps:get(sites, C).

backend_health_interval_default_test() ->
    C = pertisk_eproxy_config:json_to_config_pub(#{
        <<"backends">> => [#{
            <<"name">> => <<"web">>,
            <<"upstreams">> => [#{<<"addr">> => <<"10.0.0.1:8080">>}]
        }]
    }),
    [#{health_interval_secs := 30}] = maps:get(backends, C).

dns_provider_integer_name_test() ->
    C = pertisk_eproxy_config:json_to_config_pub(#{
        <<"dns_providers">> => [#{<<"name">> => 42, <<"provider_type">> => <<"cloudflare">>}]
    }),
    [P] = maps:get(dns_providers, C),
    ?assertEqual("42", maps:get(name, P)).

is_management_upstream_addr_invalid_upstream_test() ->
    with_config(fun() ->
        ?assertNot(pertisk_eproxy_config:is_management_upstream_addr(<<"not-an-addr">>))
    end).

is_management_upstream_addr_wrong_port_test() ->
    with_config(fun() ->
        Port = maps:get(management_port, pertisk_eproxy_config:get_config(), 9080),
        Wrong = iolist_to_binary(["127.0.0.1:", integer_to_list(Port + 1)]),
        ?assertNot(pertisk_eproxy_config:is_management_upstream_addr(Wrong))
    end).

is_management_upstream_addr_ipv6_test() ->
    with_tmp_db_config(fun() ->
        Port = 19180,
        Config = (pertisk_eproxy_config:get_config())#{
            management_port => Port,
            sites => [],
            backends => [],
            certificates => [],
            dns_providers => []
        },
        ok = put_config_retry(Config),
        Upstream = iolist_to_binary(["[::1]:", integer_to_list(Port)]),
        ?assert(pertisk_eproxy_config:is_management_upstream_addr(Upstream))
    end).

with_ingress_env(Fun) ->
    with_env("PERTISK_MODE", {set, "ingress"}, Fun).

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

%% ---------------------------------------------------------------------------
%% gen_server callbacks and metrics overrides
%% ---------------------------------------------------------------------------

config_gen_server_callbacks_test() ->
    with_config(fun() ->
        State = #{file => pertisk_eproxy_config:db_file()},
        ?assertMatch({reply, {error, unknown_call}, State},
            pertisk_eproxy_config:handle_call(unknown, self(), State)),
        ?assertMatch({noreply, State}, pertisk_eproxy_config:handle_cast(msg, State)),
        ?assertMatch({noreply, State}, pertisk_eproxy_config:handle_info(msg, State)),
        ?assertEqual(ok, pertisk_eproxy_config:terminate(normal, State)),
        ?assertMatch({ok, State}, pertisk_eproxy_config:code_change(1, State, extra))
    end).

config_metrics_listen_custom_test() ->
    with_tmp_db_config(fun() ->
        Config = (pertisk_eproxy_config:get_config())#{
            metrics_enabled => false,
            metrics_addr => {127, 0, 0, 1},
            metrics_port => 9191,
            sites => [],
            backends => [],
            certificates => [],
            dns_providers => []
        },
        ok = put_config_retry(Config),
        ?assertEqual(false, pertisk_eproxy_config:metrics_enabled()),
        ?assertEqual({{127, 0, 0, 1}, 9191}, pertisk_eproxy_config:metrics_listen())
    end).

config_reload_load_error_test() ->
    with_env("PERTISK_MODE", unset, fun() ->
        with_tmp_db_config(fun() ->
            meck:new(pertisk_eproxy_db, [unstick, passthrough]),
            meck:expect(pertisk_eproxy_db, get_runtime_config, fun(_) -> {error, corrupt} end),
            try
                ?assertNot(pertisk_eproxy_config:ingress_mode()),
                ?assertMatch({error, _}, pertisk_eproxy_config:reload())
            after
                pertisk_eproxy_test_helpers:unload_mocks([pertisk_eproxy_db])
            end
        end)
    end).

config_sync_ingress_empty_lists_test() ->
    with_config(fun() ->
        ok = pertisk_eproxy_config:sync_ingress([], []),
        ?assertEqual([], pertisk_eproxy_config:get_sites()),
        ?assertEqual([], pertisk_eproxy_config:get_backends())
    end).

config_backend_is_management_only_false_for_mixed_test() ->
    with_config(fun() ->
        Mgmt = pertisk_eproxy_config:management_loopback_upstream_bin(),
        Backends = [#{
            name => <<"mixed">>,
            algorithm => round_robin,
            upstreams => [
                #{addr => Mgmt, weight => 1},
                #{addr => <<"127.0.0.1:8080">>, weight => 1}
            ]
        }],
        ok = pertisk_eproxy_config:sync_ingress([], Backends),
        ?assertNot(pertisk_eproxy_config:backend_is_management_only(<<"mixed">>))
    end).

%% ---------------------------------------------------------------------------
%% site_auth_url / site_rate_limit / ACME scan scheduling
%% ---------------------------------------------------------------------------

site_backends() ->
    [#{
        name => <<"web">>,
        algorithm => round_robin,
        upstreams => [#{addr => <<"127.0.0.1:8080">>, weight => 1}]
    }].

site_auth_url_found_test() ->
    with_config(fun() ->
        Sites = [#{
            host => <<"auth.example">>,
            backend => <<"web">>,
            auth_url => <<"https://auth.example/login">>,
            routes => []
        }],
        ok = pertisk_eproxy_config:sync_ingress(Sites, site_backends()),
        ?assertEqual(
            <<"https://auth.example/login">>,
            pertisk_eproxy_config:site_auth_url(<<"auth.example">>)
        )
    end).

site_auth_url_missing_test() ->
    with_config(fun() ->
        Sites = [#{host => <<"plain.example">>, backend => <<"web">>, routes => []}],
        ok = pertisk_eproxy_config:sync_ingress(Sites, site_backends()),
        ?assertEqual(undefined, pertisk_eproxy_config:site_auth_url(<<"missing.example">>)),
        ?assertEqual(undefined, pertisk_eproxy_config:site_auth_url(<<"plain.example">>))
    end).

site_rate_limit_ok_test() ->
    with_config(fun() ->
        Sites = [#{
            host => <<"limited.example">>,
            backend => <<"web">>,
            rate_limit_rps => 100,
            rate_limit_burst => 200,
            routes => []
        }],
        ok = pertisk_eproxy_config:sync_ingress(Sites, site_backends()),
        ?assertEqual({ok, 100, 200}, pertisk_eproxy_config:site_rate_limit(<<"limited.example">>))
    end).

site_rate_limit_error_test() ->
    with_config(fun() ->
        Sites = [#{
            host => <<"partial.example">>,
            backend => <<"web">>,
            rate_limit_rps => 50,
            routes => []
        }],
        ok = pertisk_eproxy_config:sync_ingress(Sites, site_backends()),
        ?assertEqual(error, pertisk_eproxy_config:site_rate_limit(<<"partial.example">>)),
        ?assertEqual(error, pertisk_eproxy_config:site_rate_limit(<<"unknown.example">>))
    end).

put_config_schedules_acme_scan_test() ->
    with_tmp_db_config(fun() ->
        Self = self(),
        meck:new(pertisk_eproxy_acme_dns, [unstick]),
        meck:expect(pertisk_eproxy_acme_dns, schedule_scan, fun() ->
            Self ! acme_scan_scheduled,
            ok
        end),
        try
            Base = (pertisk_eproxy_config:get_config())#{
                sites => [],
                backends => [],
                certificates => [],
                dns_providers => []
            },
            ok = put_config_retry(Base),
            Config1 = Base#{
                sites => [#{
                    host => <<"acme.example">>,
                    backend => <<"web">>,
                    challenge_type => <<"dns-01">>,
                    dns_provider => <<"cf">>,
                    routes => []
                }],
                backends => site_backends()
            },
            ok = put_config_retry(Config1),
            receive acme_scan_scheduled -> ok after 2000 -> ?assert(false) end,
            ?assertEqual(1, meck:num_calls(pertisk_eproxy_acme_dns, schedule_scan, '_'))
        after
            pertisk_eproxy_test_helpers:unload_mocks([pertisk_eproxy_acme_dns])
        end
    end).

put_config_same_sites_no_acme_scan_test() ->
    with_tmp_db_config(fun() ->
        meck:new(pertisk_eproxy_acme_dns, [unstick]),
        meck:expect(pertisk_eproxy_acme_dns, schedule_scan, fun() -> ok end),
        try
            Config = (pertisk_eproxy_config:get_config())#{
                sites => [#{
                    host => <<"stable.example">>,
                    backend => <<"web">>,
                    routes => []
                }],
                backends => site_backends(),
                certificates => [],
                dns_providers => []
            },
            ok = put_config_retry(Config),
            timer:sleep(50),
            Calls0 = meck:num_calls(pertisk_eproxy_acme_dns, schedule_scan, '_'),
            ok = put_config_retry(Config#{http_port => maps:get(http_port, Config, 80)}),
            timer:sleep(50),
            ?assertEqual(Calls0, meck:num_calls(pertisk_eproxy_acme_dns, schedule_scan, '_'))
        after
            pertisk_eproxy_test_helpers:unload_mocks([pertisk_eproxy_acme_dns])
        end
    end).

put_config_tls_host_mismatch_test() ->
    with_tmp_db_config(fun() ->
        DbPath = pertisk_eproxy_config:db_file(),
        {CertFile, KeyFile} = listener_pem_paths(),
        {ok, CertBin} = file:read_file(CertFile),
        {ok, KeyBin} = file:read_file(KeyFile),
        {ok, _} = pertisk_eproxy_db:upsert_certificate_record(
            DbPath, <<"localhost-cert">>, binary_to_list(CertBin), binary_to_list(KeyBin), <<"imported_pem">>),
        Config = (pertisk_eproxy_config:get_config())#{
            sites => [#{
                host => <<"wrong.example.com">>,
                backend => <<"web">>,
                certificate => <<"localhost-cert">>,
                routes => []
            }],
            backends => site_backends(),
            certificates => [<<"localhost-cert">>],
            dns_providers => []
        },
        ?assertMatch(
            {error, {tls_validation_host_mismatch, _, _}},
            pertisk_eproxy_config:put_config(Config)
        )
    end).

put_config_missing_cert_pem_test() ->
    with_tmp_db_config(fun() ->
        DbPath = pertisk_eproxy_config:db_file(),
        {ok, _} = pertisk_eproxy_db:insert_certificate(DbPath, <<"no-pem">>),
        Config = (pertisk_eproxy_config:get_config())#{
            sites => [#{
                host => <<"tls.example.com">>,
                backend => <<"web">>,
                certificate => <<"no-pem">>,
                routes => []
            }],
            backends => site_backends(),
            certificates => [<<"no-pem">>],
            dns_providers => []
        },
        ?assertMatch(
            {error, {tls_validation_missing_cert_pem, _, _}},
            pertisk_eproxy_config:put_config(Config)
        )
    end).

put_config_skips_acme_and_k8s_refs_test() ->
    with_tmp_db_config(fun() ->
        Config = (pertisk_eproxy_config:get_config())#{
            sites => [
                #{
                    host => <<"acme.example">>,
                    backend => <<"web">>,
                    certificate => <<"acme/acme.example">>,
                    routes => []
                },
                #{
                    host => <<"ingress.example">>,
                    backend => <<"web">>,
                    certificate => <<"k8s/default/tls-secret">>,
                    routes => []
                }
            ],
            backends => site_backends(),
            certificates => [],
            dns_providers => []
        },
        ?assertEqual(ok, put_config_retry(Config))
    end).

put_config_redacted_dns_cleanup_on_reload_test() ->
    with_tmp_db_config(fun() ->
        DbPath = pertisk_eproxy_config:db_file(),
        {ok, _} = pertisk_eproxy_db:insert_dns_provider(
            DbPath, <<"redacted-db">>, <<"cloudflare">>, #{<<"api_token">> => <<"[redacted]">>}),
        Config = (pertisk_eproxy_config:get_config())#{
            dns_providers => [
                #{
                    name => <<"redacted-runtime">>,
                    provider_type => <<"cloudflare">>,
                    credentials => #{<<"api_token">> => <<"[redacted]">>}
                }
            ],
            sites => [],
            backends => [],
            certificates => []
        },
        ok = put_config_retry(Config),
        ?assertEqual(ok, pertisk_eproxy_config:reload()),
        {ok, Providers} = pertisk_eproxy_db:list_dns_providers(DbPath),
        Names = [maps:get(name, P) || P <- Providers],
        ?assertNot(lists:member(<<"redacted-db">>, Names)),
        ?assertNot(lists:member(<<"redacted-runtime">>, Names))
    end).

config_metrics_env_overrides_test() ->
    with_tmp_db_config(fun() ->
        Config = (pertisk_eproxy_config:get_config())#{
            metrics_enabled => true,
            metrics_addr => {10, 0, 0, 1},
            metrics_port => 9200,
            sites => [],
            backends => [],
            certificates => [],
            dns_providers => []
        },
        ok = put_config_retry(Config),
        with_env("PERTISK_METRICS_ENABLED", {set, "false"}, fun() ->
            ?assertEqual(false, pertisk_eproxy_config:metrics_enabled())
        end),
        with_env("PERTISK_METRICS_ADDR", {set, "127.0.0.1:9199"}, fun() ->
            ?assertEqual({{10, 0, 0, 1}, 9200}, pertisk_eproxy_config:metrics_listen())
        end)
    end).

put_config_persist_failure_meck_test() ->
    with_tmp_db_config(fun() ->
        meck:new(pertisk_eproxy_db, [unstick, passthrough]),
        meck:expect(pertisk_eproxy_db, put_runtime_config, fun(_, _) -> {error, persist_boom} end),
        try
            Config = (pertisk_eproxy_config:get_config())#{
                sites => [],
                backends => [],
                certificates => [],
                dns_providers => []
            },
            ?assertMatch(
                {error, {persist_runtime_config, persist_boom}},
                pertisk_eproxy_config:put_config(Config)
            )
        after
            pertisk_eproxy_test_helpers:unload_mocks([pertisk_eproxy_db])
        end
    end).

reload_schedules_acme_scan_in_proxy_mode_test() ->
    with_tmp_db_config(fun() ->
        Self = self(),
        meck:new(pertisk_eproxy_acme_dns, [unstick]),
        meck:expect(pertisk_eproxy_acme_dns, schedule_scan, fun() ->
            Self ! acme_scan_on_reload,
            ok
        end),
        try
            ?assertEqual(ok, pertisk_eproxy_config:reload()),
            receive acme_scan_on_reload -> ok after 2000 -> ?assert(false) end,
            ?assertEqual(1, meck:num_calls(pertisk_eproxy_acme_dns, schedule_scan, '_'))
        after
            pertisk_eproxy_test_helpers:unload_mocks([pertisk_eproxy_acme_dns])
        end
    end).

listener_pem_paths() ->
    Base = filename:join([code:priv_dir(pertisk_eproxy), "tls"]),
    {filename:join(Base, "listener.pem"), filename:join(Base, "listener.key")}.

generated_cert_files(Host) when is_binary(Host) ->
    Base = filename:join([
        os:getenv("TMPDIR", "/tmp"),
        "cfg_cert_" ++ integer_to_list(erlang:unique_integer([positive]))
    ]),
    CertFile = Base ++ ".pem",
    KeyFile = Base ++ ".key",
    HostStr = binary_to_list(Host),
    Subj = "/CN=" ++ HostStr,
    Ext = "subjectAltName=DNS:" ++ HostStr,
    Cmd = "openssl req -x509 -newkey rsa:2048 -nodes -days 1 "
        "-subj '" ++ Subj ++ "' "
        "-addext '" ++ Ext ++ "' "
        "-keyout " ++ KeyFile ++ " -out " ++ CertFile ++ " 2>/dev/null",
    _ = os:cmd(Cmd),
    {CertFile, KeyFile}.

%% ---------------------------------------------------------------------------
%% Additional coverage (metrics env, TLS validation branches, DNS cleanup)
%% ---------------------------------------------------------------------------

config_metrics_env_true_and_one_test() ->
    with_config(fun() ->
        with_env("PERTISK_METRICS_ENABLED", {set, "true"}, fun() ->
            ?assertEqual(true, pertisk_eproxy_config:metrics_enabled())
        end),
        with_env("PERTISK_METRICS_ENABLED", {set, "1"}, fun() ->
            ?assertEqual(true, pertisk_eproxy_config:metrics_enabled())
        end),
        with_env("PERTISK_METRICS_ENABLED", {set, "0"}, fun() ->
            ?assertEqual(false, pertisk_eproxy_config:metrics_enabled())
        end)
    end).

config_metrics_listen_env_parse_test() ->
    with_tmp_db_config(fun() ->
        Config = (pertisk_eproxy_config:get_config())#{
            metrics_addr => {10, 0, 0, 2},
            metrics_port => 9292,
            sites => [],
            backends => [],
            certificates => [],
            dns_providers => []
        },
        ok = put_config_retry(Config),
        with_env("PERTISK_METRICS_ADDR", {set, "not-valid"}, fun() ->
            ?assertEqual({{10, 0, 0, 2}, 9292}, pertisk_eproxy_config:metrics_listen())
        end)
    end).

backend_is_management_only_edge_cases_test() ->
    with_config(fun() ->
        ?assertNot(pertisk_eproxy_config:backend_is_management_only(<<"missing">>)),
        ?assertNot(pertisk_eproxy_config:backend_is_management_only(not_binary)),
        Backends = [#{name => <<"empty">>, algorithm => round_robin, upstreams => []}],
        ok = pertisk_eproxy_config:sync_ingress([], Backends),
        ?assertNot(pertisk_eproxy_config:backend_is_management_only(<<"empty">>))
    end).

put_config_valid_matching_cert_test() ->
    with_tmp_db_config(fun() ->
        DbPath = pertisk_eproxy_config:db_file(),
        Host = <<"valid.example">>,
        {CertFile, KeyFile} = generated_cert_files(Host),
        {ok, CertBin} = file:read_file(CertFile),
        {ok, KeyBin} = file:read_file(KeyFile),
        {ok, _} = pertisk_eproxy_db:upsert_certificate_record(
            DbPath, <<"valid-cert">>, binary_to_list(CertBin), binary_to_list(KeyBin), <<"imported_pem">>),
        Config = (pertisk_eproxy_config:get_config())#{
            sites => [#{
                host => Host,
                backend => <<"web">>,
                certificate => <<"valid-cert">>,
                routes => []
            }],
            backends => site_backends(),
            certificates => [<<"valid-cert">>],
            dns_providers => []
        },
        ?assertEqual(ok, put_config_retry(Config)),
        file:delete(CertFile),
        file:delete(KeyFile)
    end).

put_config_tls_listener_cert_skipped_test() ->
    with_tmp_db_config(fun() ->
        DbPath = pertisk_eproxy_config:db_file(),
        {CertFile, KeyFile} = listener_pem_paths(),
        {ok, CertBin} = file:read_file(CertFile),
        {ok, KeyBin} = file:read_file(KeyFile),
        {ok, _} = pertisk_eproxy_db:upsert_certificate_record(
            DbPath, <<"listener-tls">>, binary_to_list(CertBin), binary_to_list(KeyBin), <<"tls_listener">>),
        Config = (pertisk_eproxy_config:get_config())#{
            sites => [#{
                host => <<"any.example">>,
                backend => <<"web">>,
                certificate => <<"listener-tls">>,
                routes => []
            }],
            backends => site_backends(),
            certificates => [<<"listener-tls">>],
            dns_providers => []
        },
        ?assertEqual(ok, put_config_retry(Config))
    end).

put_config_cert_ref_by_id_test() ->
    with_tmp_db_config(fun() ->
        DbPath = pertisk_eproxy_config:db_file(),
        Host = <<"id.example">>,
        {CertFile, KeyFile} = generated_cert_files(Host),
        {ok, CertBin} = file:read_file(CertFile),
        {ok, KeyBin} = file:read_file(KeyFile),
        {ok, Id} = pertisk_eproxy_db:upsert_certificate_record(
            DbPath, <<"id-cert">>, binary_to_list(CertBin), binary_to_list(KeyBin), <<"imported_pem">>),
        Config = (pertisk_eproxy_config:get_config())#{
            sites => [#{
                host => Host,
                backend => <<"web">>,
                certificate => integer_to_binary(Id),
                routes => []
            }],
            backends => site_backends(),
            certificates => [<<"id-cert">>],
            dns_providers => []
        },
        ?assertEqual(ok, put_config_retry(Config)),
        file:delete(CertFile),
        file:delete(KeyFile)
    end).

put_config_unchanged_tls_site_skips_validation_test() ->
    with_tmp_db_config(fun() ->
        Config0 = (pertisk_eproxy_config:get_config())#{
            sites => [#{
                host => <<"stable-tls.example">>,
                backend => <<"web">>,
                certificate => <<"acme/stable-tls.example">>,
                routes => []
            }],
            backends => site_backends(),
            certificates => [],
            dns_providers => []
        },
        ?assertEqual(ok, put_config_retry(Config0)),
        Config1 = Config0#{http_port => maps:get(http_port, Config0, 80)},
        ?assertEqual(ok, put_config_retry(Config1))
    end).

put_config_persist_dns_providers_failure_test() ->
    with_tmp_db_config(fun() ->
        meck:new(pertisk_eproxy_db, [unstick, passthrough]),
        meck:expect(pertisk_eproxy_db, replace_dns_providers, fun(_, _) -> {error, dns_boom} end),
        try
            Config = (pertisk_eproxy_config:get_config())#{
                sites => [],
                backends => [],
                certificates => [],
                dns_providers => [#{name => <<"cf">>, provider_type => <<"label">>, credentials => #{}}]
            },
            ?assertMatch(
                {error, {persist_runtime_config, {persist_dns_providers, dns_boom}}},
                pertisk_eproxy_config:put_config(Config)
            )
        after
            pertisk_eproxy_test_helpers:unload_mocks([pertisk_eproxy_db])
        end
    end).

put_config_cert_store_unavailable_test() ->
    with_tmp_db_config(fun() ->
        meck:new(pertisk_eproxy_db, [unstick, passthrough]),
        meck:expect(pertisk_eproxy_db, list_certificates, fun(_) -> {error, db_down} end),
        try
            Config = (pertisk_eproxy_config:get_config())#{
                sites => [#{
                    host => <<"tls.example">>,
                    backend => <<"web">>,
                    certificate => <<"any-cert">>,
                    routes => []
                }],
                backends => site_backends(),
                certificates => [],
                dns_providers => []
            },
            ?assertMatch(
                {error, {tls_validation_cert_store_unavailable, db_down}},
                pertisk_eproxy_config:put_config(Config)
            )
        after
            pertisk_eproxy_test_helpers:unload_mocks([pertisk_eproxy_db])
        end
    end).

ingress_mode_from_config_map_test() ->
    with_env("PERTISK_MODE", unset, fun() ->
        with_tmp_db_config(fun() ->
            Config = (pertisk_eproxy_config:get_config())#{
                mode => ingress,
                sites => [],
                backends => [],
                certificates => [],
                dns_providers => []
            },
            ok = put_config_retry(Config),
            ?assert(pertisk_eproxy_config:ingress_mode()),
            ?assertNot(pertisk_eproxy_config:proxy_mode())
        end)
    end).

nested_redacted_dns_credentials_cleanup_test() ->
    with_tmp_db_config(fun() ->
        Config = (pertisk_eproxy_config:get_config())#{
            dns_providers => [
                #{
                    name => <<"nested-redacted">>,
                    provider_type => <<"cloudflare">>,
                    credentials => #{<<"nested">> => #{<<"api_token">> => <<"[redacted]">>}}
                }
            ],
            sites => [],
            backends => [],
            certificates => []
        },
        ok = put_config_retry(Config),
        ?assertEqual(ok, pertisk_eproxy_config:reload()),
        {ok, Providers} = pertisk_eproxy_db:list_dns_providers(pertisk_eproxy_config:db_file()),
        Names = [maps:get(name, P) || P <- Providers],
        ?assertNot(lists:member(<<"nested-redacted">>, Names))
    end).

otel_and_rate_limit_json_parsing_test() ->
    C = pertisk_eproxy_config:json_to_config_pub(#{
        <<"otel_enabled">> => true,
        <<"otel_service_name">> => <<"eproxy">>,
        <<"rate_limit_enabled">> => false,
        <<"rate_limit_rps">> => 50,
        <<"rate_limit_burst">> => 100
    }),
    ?assertEqual(true, maps:get(otel_enabled, C)),
    ?assertEqual("eproxy", maps:get(otel_service_name, C)),
    ?assertEqual(false, maps:get(rate_limit_enabled, C)),
    ?assertEqual(50, maps:get(rate_limit_rps, C)),
    ?assertEqual(100, maps:get(rate_limit_burst, C)).

dns_provider_legacy_binary_name_test() ->
    C = pertisk_eproxy_config:json_to_config_pub(#{
        <<"dns_providers">> => [123]
    }),
    ?assertEqual([], maps:get(dns_providers, C)).

sanitize_runtime_tls_redacted_pair_test() ->
    with_tmp_db_config(fun() ->
        DbPath = pertisk_eproxy_config:db_file(),
        Cfg = #{
            mode => proxy,
            tls_cert_file => "[redacted]",
            tls_key_file => "/etc/key.pem",
            sites => [],
            backends => []
        },
        ?assertEqual(ok, pertisk_eproxy_db:put_runtime_config(DbPath, Cfg)),
        ?assertEqual(ok, pertisk_eproxy_config:reload()),
        C = pertisk_eproxy_config:get_config(),
        ?assertEqual(false, maps:is_key(tls_cert_file, C)),
        ?assertEqual(false, maps:is_key(tls_key_file, C))
    end).

config_init_bad_config_file_test() ->
    with_env("PERTISK_CONFIG_FILE", unset, fun() ->
        Tmp = filename:join([
            os:getenv("TMPDIR", "/tmp"),
            "bad-proxy-" ++ integer_to_list(erlang:unique_integer([positive])) ++ ".json"
        ]),
        ok = file:write_file(Tmp, <<"{not json">>),
        Old = application:get_env(pertisk_eproxy, config_file),
        application:set_env(pertisk_eproxy, config_file, Tmp),
        Started = case whereis(pertisk_eproxy_config) of
            undefined ->
                ?assertMatch({ok, _}, pertisk_eproxy_config:start_link()),
                true;
            _ ->
                stop_config_if_running(),
                ?assertMatch({ok, _}, pertisk_eproxy_config:start_link()),
                true
        end,
        try
            ?assert(is_map(pertisk_eproxy_config:get_config()))
        after
            case Started of
                true -> stop_config_if_running();
                false -> ok
            end,
            file:delete(Tmp),
            case Old of
                {ok, V} -> application:set_env(pertisk_eproxy, config_file, V);
                undefined -> application:unset_env(pertisk_eproxy, config_file)
            end
        end
    end).

%% ---------------------------------------------------------------------------
%% Coverage: init failure, empty lookups, JSON branches, TLS skip paths
%% ---------------------------------------------------------------------------

is_management_upstream_addr_non_binary_test() ->
    with_config(fun() ->
        ?assertNot(pertisk_eproxy_config:is_management_upstream_addr(12345))
    end).

config_lookups_without_server_test() ->
    stop_config_if_running(),
    ?assertEqual([], pertisk_eproxy_config:get_sites()),
    ?assertEqual([], pertisk_eproxy_config:get_backends()),
    ?assertEqual([], pertisk_eproxy_config:get_certificates()),
    ?assertEqual([], pertisk_eproxy_config:get_dns_providers()),
    ?assertEqual([], pertisk_eproxy_config:get_router()).

config_init_ingress_load_failure_test() ->
    with_env("PERTISK_MODE", {set, "ingress"}, fun() ->
        Tmp = filename:join([
            os:getenv("TMPDIR", "/tmp"),
            "bad-ingress-" ++ integer_to_list(erlang:unique_integer([positive])) ++ ".json"
        ]),
        ok = file:write_file(Tmp, <<"{not json">>),
        OldFile = application:get_env(pertisk_eproxy, config_file),
        application:set_env(pertisk_eproxy, config_file, Tmp),
        stop_config_if_running(),
        ?assertMatch({ok, _}, pertisk_eproxy_config:start_link()),
        try
            ?assertEqual(#{}, pertisk_eproxy_config:get_config()),
            ?assertEqual([], pertisk_eproxy_config:get_sites()),
            ?assertEqual([], pertisk_eproxy_config:get_backends())
        after
            stop_config_if_running(),
            file:delete(Tmp),
            case OldFile of
                {ok, V} -> application:set_env(pertisk_eproxy, config_file, V);
                undefined -> application:unset_env(pertisk_eproxy, config_file)
            end
        end
    end).

put_config_skips_site_without_certificate_test() ->
    with_tmp_db_config(fun() ->
        Base = (pertisk_eproxy_config:get_config())#{
            sites => [],
            backends => site_backends(),
            certificates => [],
            dns_providers => []
        },
        ok = put_config_retry(Base),
        Config = Base#{
            sites => [#{host => <<"nocert.example">>, backend => <<"web">>, routes => []}]
        },
        ?assertEqual(ok, pertisk_eproxy_config:put_config(Config))
    end).

management_tls_enabled_non_bool_test() ->
    C = pertisk_eproxy_config:json_to_config_pub(#{<<"management_tls_enabled">> => <<"yes">>}),
    ?assertEqual(false, maps:get(management_tls_enabled, C)).

route_path_type_unknown_defaults_prefix_test() ->
    C = pertisk_eproxy_config:json_to_config_pub(#{
        <<"sites">> => [#{
            <<"host">> => <<"h.example">>,
            <<"backend">> => <<"b">>,
            <<"routes">> => [#{<<"path">> => <<"/">>, <<"path_type">> => <<"regex">>}]
        }]
    }),
    Site = hd(maps:get(sites, C)),
    Route = hd(maps:get(routes, Site)),
    ?assertEqual(prefix, maps:get(path_type, Route)).

dns_provider_integer_name_json_test() ->
    C = pertisk_eproxy_config:json_to_config_pub(#{
        <<"dns_providers">> => [#{<<"name">> => 42, <<"provider_type">> => <<"cf">>}]
    }),
    [P] = maps:get(dns_providers, C),
    ?assertEqual("42", maps:get(name, P)).

get_dns_providers_legacy_binary_entry_test() ->
    with_tmp_db_config(fun() ->
        Config = (pertisk_eproxy_config:get_config())#{
            dns_providers => [#{name => <<"legacy">>, provider_type => <<"label">>, credentials => #{}}],
            sites => [],
            backends => [],
            certificates => []
        },
        ok = put_config_retry(Config),
        ?assertEqual(["legacy"], pertisk_eproxy_config:get_dns_providers())
    end).

rebuild_runtime_config_from_db_test() ->
    with_tmp_db_config(fun() ->
        DbPath = pertisk_eproxy_config:db_file(),
        ?assertEqual(ok, pertisk_eproxy_db:migrate_schema(DbPath)),
        _ = os:cmd("sqlite3 " ++ DbPath ++ " \"DROP TABLE IF EXISTS runtime_state;\""),
        _ = os:cmd("sqlite3 " ++ DbPath ++ " \"INSERT INTO sites(host, backend, routes_json) "
            "VALUES('rebuild.example', 'web', '[]');\""),
        ?assertEqual(ok, pertisk_eproxy_config:reload()),
        Sites = pertisk_eproxy_config:get_sites(),
        ?assertEqual(1, length(Sites)),
        ?assertEqual(<<"rebuild.example">>, maps:get(host, hd(Sites)))
    end).
