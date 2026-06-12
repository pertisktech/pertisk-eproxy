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
    with_config(fun() ->
        ?assertNot(pertisk_eproxy_config:ingress_mode())
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
        _ = catch pertisk_eproxy_config:put_config(BaseConfig),
        catch pertisk_eproxy_config:sync_ingress(BaseSites, BaseBackends),
        maybe_stop_config(Started)
    end.

init_tmp_db(DbPath) ->
    init_tmp_db(DbPath, 12).

put_config_retry(Config) ->
    put_config_retry(Config, 12).

put_config_retry(Config, 0) ->
    pertisk_eproxy_config:put_config(Config);
put_config_retry(Config, Retries) ->
    case pertisk_eproxy_config:put_config(Config) of
        ok ->
            ok;
        {error, Reason} when Retries > 0 ->
            case config_locked_error(Reason) of
                true ->
                    timer:sleep(75),
                    put_config_retry(Config, Retries - 1);
                false ->
                    {error, Reason}
            end;
        Other ->
            Other
    end.

config_locked_error({persist_runtime_config, Inner}) ->
    config_locked_error(Inner);
config_locked_error({persist_dns_providers, Inner}) ->
    config_locked_error(Inner);
config_locked_error({tls_validation_cert_store_unavailable, Inner}) ->
    config_locked_error(Inner);
config_locked_error({sqlite_error, Msg, _}) ->
    sqlite_locked_msg(Msg);
config_locked_error({sqlite_error, Msg}) when is_list(Msg) ->
    string:find(Msg, "locked") =/= nomatch;
config_locked_error({sqlite3_cli, Msg}) when is_list(Msg) ->
    string:find(Msg, "locked") =/= nomatch;
config_locked_error({sqlite3_cli, Msg}) when is_binary(Msg) ->
    sqlite_locked_msg(Msg);
config_locked_error(Msg) when is_binary(Msg) ->
    sqlite_locked_msg(Msg);
config_locked_error(Msg) when is_list(Msg) ->
    string:find(Msg, "locked") =/= nomatch;
config_locked_error(_) ->
    false.

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

with_tmp_db_config(Fun) ->
    pertisk_eproxy_test_helpers:with_db_lock(fun() ->
        DbPath = pertisk_eproxy_test_helpers:tmp_db(),
        file:delete(DbPath),
        OldDb = application:get_env(pertisk_eproxy, db_file),
        stop_config_if_running(),
        application:set_env(pertisk_eproxy, db_file, DbPath),
        try
            ?assertMatch({ok, _}, init_tmp_db(DbPath)),
            with_config(Fun)
        after
            stop_config_if_running(),
            case OldDb of
                {ok, V} -> application:set_env(pertisk_eproxy, db_file, V);
                undefined -> application:unset_env(pertisk_eproxy, db_file)
            end,
            file:delete(DbPath)
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
        ok = pertisk_eproxy_config:put_config(Config),
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
        ok = pertisk_eproxy_config:put_config(Config),
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
    with_config(fun() ->
        ?assert(pertisk_eproxy_config:proxy_mode())
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
            Self = self(),
            meck:new(pertisk_ingress_watcher, [unstick]),
            meck:expect(pertisk_ingress_watcher, trigger_reconcile, fun() ->
                Self ! reconcile_triggered,
                ok
            end),
            try
                ?assertEqual(ok, pertisk_eproxy_config:reload()),
                receive reconcile_triggered -> ok after 1000 -> ?assert(false) end
            after
                meck:unload(pertisk_ingress_watcher)
            end
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
        ok = pertisk_eproxy_config:put_config(Config),
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
        ok = pertisk_eproxy_config:put_config(Config),
        ?assertEqual(false, pertisk_eproxy_config:metrics_enabled()),
        ?assertEqual({{127, 0, 0, 1}, 9191}, pertisk_eproxy_config:metrics_listen())
    end).

config_reload_load_error_test() ->
    with_tmp_db_config(fun() ->
        meck:new(pertisk_eproxy_db, [unstick, passthrough]),
        meck:expect(pertisk_eproxy_db, get_runtime_config, fun(_) -> {error, corrupt} end),
        try
            ?assertMatch({error, _}, pertisk_eproxy_config:reload())
        after
            meck:unload(pertisk_eproxy_db)
        end
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
