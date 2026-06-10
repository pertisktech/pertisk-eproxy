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
