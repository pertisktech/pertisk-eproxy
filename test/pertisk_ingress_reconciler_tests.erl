-module(pertisk_ingress_reconciler_tests).

-include_lib("eunit/include/eunit.hrl").

ingress_matches_class_by_spec_test() ->
    Ingress = #{
        <<"metadata">> => #{},
        <<"spec">> => #{<<"ingressClassName">> => <<"pertisk-eproxy">>}
    },
    ?assert(pertisk_ingress_reconciler:ingress_matches_class(Ingress, {ok, <<"pertisk-eproxy">>})),
    ?assertNot(pertisk_ingress_reconciler:ingress_matches_class(Ingress, {ok, <<"other">>})),
    ?assert(pertisk_ingress_reconciler:ingress_matches_class(Ingress, all)).

ingress_matches_class_by_annotation_test() ->
    Ingress = #{
        <<"metadata">> => #{
            <<"annotations">> => #{<<"kubernetes.io/ingress.class">> => <<"legacy-class">>}
        },
        <<"spec">> => #{}
    },
    ?assert(pertisk_ingress_reconciler:ingress_matches_class(Ingress, {ok, <<"legacy-class">>})).

reconcile_empty_lists_test() ->
    {ok, Result} = pertisk_ingress_reconciler:reconcile([], []),
    ?assertEqual([], maps:get(sites, Result)),
    ?assertEqual([], maps:get(backends, Result)),
    ?assertEqual([], maps:get(tls, Result)).

reconcile_skips_wrong_class_test() ->
    Ingress = #{
        <<"metadata">> => #{<<"name">> => <<"x">>},
        <<"spec">> => #{<<"ingressClassName">> => <<"other">>},
        <<"rules">> => []
    },
    {ok, Result} = pertisk_ingress_reconciler:reconcile([Ingress], []),
    ?assertEqual([], maps:get(sites, Result)).

listener_pems() ->
    CertPath = filename:join([code:priv_dir(pertisk_eproxy), "tls", "listener.pem"]),
    KeyPath = filename:join([code:priv_dir(pertisk_eproxy), "tls", "listener.key"]),
    {ok, CertPem} = file:read_file(CertPath),
    {ok, KeyPem} = file:read_file(KeyPath),
    {CertPem, KeyPem}.

tls_secret(Ns, Name, CertPem, KeyPem) ->
    #{
        <<"type">> => <<"kubernetes.io/tls">>,
        <<"metadata">> => #{<<"name">> => Name, <<"namespace">> => Ns},
        <<"data">> => #{
            <<"tls.crt">> => base64:encode(CertPem),
            <<"tls.key">> => base64:encode(KeyPem)
        }
    }.

sample_ingress(Opts) ->
    #{
        <<"metadata">> => maps:merge(#{
            <<"name">> => <<"test-ing">>,
            <<"namespace">> => maps:get(namespace, Opts, <<"default">>),
            <<"annotations">> => maps:get(annotations, Opts, #{})
        }, maps:get(metadata_extra, Opts, #{})),
        <<"spec">> => maps:merge(#{
            <<"ingressClassName">> => <<"pertisk-eproxy">>,
            <<"rules">> => maps:get(rules, Opts, [sample_rule(Opts)]),
            <<"tls">> => maps:get(tls, Opts, [])
        }, maps:get(spec_extra, Opts, #{}))
    }.

sample_rule(Opts) ->
    #{
        <<"host">> => maps:get(host, Opts, <<"app.example.com">>),
        <<"http">> => #{
            <<"paths">> => maps:get(paths, Opts, [sample_path(Opts)])
        }
    }.

sample_path(Opts) ->
    #{
        <<"path">> => maps:get(path, Opts, <<"/">>),
        <<"pathType">> => maps:get(path_type, Opts, <<"Prefix">>),
        <<"backend">> => maps:get(backend, Opts, service_backend(<<"web">>, 8080))
    }.

service_backend(Name, Port) ->
    #{
        <<"service">> => #{
            <<"name">> => Name,
            <<"port">> => #{<<"number">> => Port}
        }
    }.

reconcile_service_backend_test() ->
    Ingress = sample_ingress(#{}),
    {ok, Result} = pertisk_ingress_reconciler:reconcile([Ingress], []),
    [Site] = maps:get(sites, Result),
    [Backend] = maps:get(backends, Result),
    ?assertEqual(<<"app.example.com">>, maps:get(host, Site)),
    ?assertEqual(<<"web.default.test-ing:8080">>, maps:get(name, Backend)),
    Addr = maps:get(addr, hd(maps:get(upstreams, Backend))),
    ?assertNotEqual(nomatch, binary:match(Addr, <<"web.default.svc.cluster.local:8080">>)).

reconcile_tls_from_secret_test() ->
    {CertPem, KeyPem} = listener_pems(),
    Ingress = sample_ingress(#{
        tls => [#{<<"secretName">> => <<"tls-secret">>, <<"hosts">> => [<<"tls.example.com">>]}]
    }),
    Secret = tls_secret(<<"default">>, <<"tls-secret">>, CertPem, KeyPem),
    {ok, Result} = pertisk_ingress_reconciler:reconcile([Ingress], [Secret]),
    [Tls] = maps:get(tls, Result),
    ?assertEqual([<<"tls.example.com">>], maps:get(hosts, Tls)),
    [Site] = maps:get(sites, Result),
    ?assertEqual(<<"k8s/default/tls-secret">>, maps:get(certificate, Site)).

reconcile_annotations_test() ->
    Ingress = sample_ingress(#{
        annotations => #{
            <<"pertisk.io/backend-namespace">> => <<"backend-ns">>,
            <<"pertisk.io/backend-namespaces">> => <<"{\"web\":\"svc-ns\"}">>,
            <<"pertisk.io/advertise-http3">> => <<"false">>,
            <<"pertisk.io/sse-early-flush">> => <<"true">>,
            <<"pertisk.io/sse-early-flush-paths">> => <<"{\"prefix:/api\":false}">>
        },
        paths => [
            sample_path(#{
                path => <<"/api">>,
                path_type => <<"Exact">>,
                backend => service_backend(<<"web">>, 80)
            })
        ]
    }),
    {ok, Result} = pertisk_ingress_reconciler:reconcile([Ingress], []),
    [Site] = maps:get(sites, Result),
    ?assertEqual(false, maps:get(advertise_http3, Site)),
    ?assertEqual(true, maps:get(sse_early_flush, Site)),
    [Route] = maps:get(routes, Site),
    ?assertEqual(false, maps:get(sse_early_flush, Route)),
    [Backend] = maps:get(backends, Result),
    Addr = maps:get(addr, hd(maps:get(upstreams, Backend))),
    ?assertNotEqual(nomatch, binary:match(Addr, <<"web.svc-ns.svc.cluster.local:80">>)).

reconcile_legacy_annotations_test() ->
    Ingress = sample_ingress(#{
        annotations => #{
            <<"pertisk.tech/backend-namespace">> => <<"legacy-ns">>,
            <<"pertisk.tech/advertise-http3">> => <<"0">>
        }
    }),
    {ok, Result} = pertisk_ingress_reconciler:reconcile([Ingress], []),
    [Site] = maps:get(sites, Result),
    ?assertEqual(false, maps:get(advertise_http3, Site)),
    [Backend] = maps:get(backends, Result),
    Addr = maps:get(addr, hd(maps:get(upstreams, Backend))),
    ?assertNotEqual(nomatch, binary:match(Addr, <<"web.legacy-ns.svc.cluster.local:8080">>)).

reconcile_resource_backend_test() ->
    Ingress = sample_ingress(#{
        paths => [
            sample_path(#{
                backend => #{<<"resource">> => #{<<"name">> => <<"my-resource">>}}
            })
        ]
    }),
    {ok, Result} = pertisk_ingress_reconciler:reconcile([Ingress], []),
    [Backend] = maps:get(backends, Result),
    ?assertEqual(<<"resource.my-resource.default.test-ing">>, maps:get(name, Backend)),
    ?assertEqual([], maps:get(upstreams, Backend)).

reconcile_dedupes_backends_test() ->
    Ingress = sample_ingress(#{
        rules => [
            sample_rule(#{host => <<"a.example">>, paths => [sample_path(#{})]}),
            sample_rule(#{host => <<"b.example">>, paths => [sample_path(#{})]})
        ]
    }),
    {ok, Result} = pertisk_ingress_reconciler:reconcile([Ingress], []),
    ?assertEqual(1, length(maps:get(backends, Result))),
    ?assertEqual(2, length(maps:get(sites, Result))).

reconcile_skips_rule_without_http_test() ->
    Ingress = sample_ingress(#{
        rules => [#{<<"host">> => <<"nohttp.example">>}]
    }),
    {ok, Result} = pertisk_ingress_reconciler:reconcile([Ingress], []),
    ?assertEqual([], maps:get(sites, Result)).

reconcile_tls_secret_errors_test() ->
    Ingress = sample_ingress(#{
        tls => [#{<<"secretName">> => <<"missing">>, <<"hosts">> => [<<"x.example">>]}]
    }),
    {ok, Result} = pertisk_ingress_reconciler:reconcile([Ingress], []),
    ?assertEqual([], maps:get(tls, Result)),
    BadSecret = #{
        <<"metadata">> => #{<<"name">> => <<"bad">>, <<"namespace">> => <<"default">>},
        <<"type">> => <<"Opaque">>,
        <<"data">> => #{}
    },
    Ingress2 = sample_ingress(#{
        tls => [#{<<"secretName">> => <<"bad">>, <<"hosts">> => [<<"x.example">>]}]
    }),
    {ok, Result2} = pertisk_ingress_reconciler:reconcile([Ingress2], [BadSecret]),
    ?assertEqual([], maps:get(tls, Result2)),
    {CertPem, KeyPem} = listener_pems(),
    EmptySecret = tls_secret(<<"default">>, <<"empty">>, <<>>, KeyPem),
    Ingress3 = sample_ingress(#{
        tls => [#{<<"secretName">> => <<"empty">>, <<"hosts">> => [<<"x.example">>]}]
    }),
    {ok, Result3} = pertisk_ingress_reconciler:reconcile([Ingress3], [EmptySecret]),
    ?assertEqual([], maps:get(tls, Result3)).

reconcile_ingress_mode_mgmt_port_test() ->
    pertisk_eproxy_test_helpers:ensure_config(),
    Old = os:getenv("PERTISK_MODE"),
    os:putenv("PERTISK_MODE", "ingress"),
    try
        Mgmt = maps:get(management_port, pertisk_eproxy_config:get_config(), 9080),
        Ingress = sample_ingress(#{
            paths => [sample_path(#{
                backend => service_backend(<<"admin">>, Mgmt)
            })]
        }),
        {ok, Result} = pertisk_ingress_reconciler:reconcile([Ingress], []),
        [Backend] = maps:get(backends, Result),
        Addr = maps:get(addr, hd(maps:get(upstreams, Backend))),
        ?assertEqual(pertisk_eproxy_config:management_loopback_upstream_bin(), Addr)
    after
        case Old of false -> os:unsetenv("PERTISK_MODE"); V -> os:putenv("PERTISK_MODE", V) end
    end.

reconcile_path_types_test() ->
    Ingress = sample_ingress(#{
        paths => [
            sample_path(#{path_type => <<"ImplementationSpecific">>}),
            sample_path(#{path_type => <<"Unknown">>, path => <<"/other">>})
        ]
    }),
    {ok, Result} = pertisk_ingress_reconciler:reconcile([Ingress], []),
    ?assertEqual(2, length(maps:get(sites, Result))).

reconcile_tls_uses_rule_hosts_when_empty_test() ->
    {CertPem, KeyPem} = listener_pems(),
    Ingress = sample_ingress(#{
        tls => [#{<<"secretName">> => <<"tls-secret">>}]
    }),
    Secret = tls_secret(<<"default">>, <<"tls-secret">>, CertPem, KeyPem),
    {ok, Result} = pertisk_ingress_reconciler:reconcile([Ingress], [Secret]),
    [Tls] = maps:get(tls, Result),
    ?assertEqual([<<"app.example.com">>], maps:get(hosts, Tls)).

reconcile_invalid_backend_namespace_json_test() ->
    Ingress = sample_ingress(#{
        annotations => #{<<"pertisk.io/backend-namespaces">> => <<"not-json">>}
    }),
    {ok, Result} = pertisk_ingress_reconciler:reconcile([Ingress], []),
    ?assertEqual(1, length(maps:get(sites, Result))).

reconcile_catch_returns_error_test() ->
    BadIngress = #{<<"metadata">> => bad_metadata},
    ?assertMatch({error, {reconcile_failed, _, _, _}},
        pertisk_ingress_reconciler:reconcile([BadIngress], [])).
