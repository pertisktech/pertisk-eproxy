-module(pertisk_gateway_reconciler_tests).

-include_lib("eunit/include/eunit.hrl").

sample_route(Opts) ->
    #{
        <<"metadata">> => #{
            <<"name">> => <<"api-route">>,
            <<"namespace">> => maps:get(namespace, Opts, <<"default">>),
            <<"annotations">> => maps:get(annotations, Opts, #{
                <<"pertisk.io/gateway-class">> => <<"pertisk-eproxy">>
            })
        },
        <<"spec">> => #{
            <<"hostnames">> => [maps:get(host, Opts, <<"api.example.com">>)],
            <<"rules">> => [
                #{
                    <<"matches">> => [
                        #{<<"path">> => #{<<"type">> => <<"PathPrefix">>, <<"value">> => <<"/v1">>}}
                    ],
                    <<"backendRefs">> => [
                        #{<<"name">> => <<"backend">>, <<"port">> => 8080}
                    ]
                }
            ]
        }
    }.

sample_gateway() ->
    #{
        <<"metadata">> => #{
            <<"name">> => <<"pertisk-gateway">>,
            <<"namespace">> => <<"pertisk-eproxy">>
        },
        <<"spec">> => #{
            <<"gatewayClassName">> => <<"pertisk-eproxy">>,
            <<"listeners">> => [
                #{
                    <<"hostname">> => <<"*.gateway.pertisk.com">>,
                    <<"tls">> => #{
                        <<"certificateRefs">> => [
                            #{<<"kind">> => <<"Secret">>, <<"name">> => <<"admin-gateway-pertisk-tls">>}
                        ]
                    }
                }
            ]
        }
    }.

tls_secret() ->
    CertPath = filename:join([code:priv_dir(pertisk_eproxy), "tls", "listener.pem"]),
    KeyPath = filename:join([code:priv_dir(pertisk_eproxy), "tls", "listener.key"]),
    {ok, CertPem} = file:read_file(CertPath),
    {ok, KeyPem} = file:read_file(KeyPath),
    #{
        <<"type">> => <<"kubernetes.io/tls">>,
        <<"metadata">> => #{
            <<"name">> => <<"admin-gateway-pertisk-tls">>,
            <<"namespace">> => <<"pertisk-eproxy">>
        },
        <<"data">> => #{
            <<"tls.crt">> => base64:encode(CertPem),
            <<"tls.key">> => base64:encode(KeyPem)
        }
    }.

with_class(Env, Fun) ->
    Old = os:getenv("PERTISK_K8S_INGRESS_CLASS"),
    os:putenv("PERTISK_K8S_INGRESS_CLASS", Env),
    try Fun() after
        case Old of false -> os:unsetenv("PERTISK_K8S_INGRESS_CLASS"); V -> os:putenv("PERTISK_K8S_INGRESS_CLASS", V) end
    end.

reconcile_httproute_test() ->
    with_class("pertisk-eproxy", fun() ->
        {ok, Result} = pertisk_gateway_reconciler:reconcile([sample_route(#{})]),
        [Site] = maps:get(sites, Result),
        ?assertEqual(<<"api.example.com">>, maps:get(host, Site)),
        [Backend] = maps:get(backends, Result),
        Addr = maps:get(addr, hd(maps:get(upstreams, Backend))),
        ?assertNotEqual(nomatch, binary:match(Addr, <<"backend.default.svc.cluster.local:8080">>))
    end).

reconcile_tls_from_gateway_listener_test() ->
    with_class("pertisk-eproxy", fun() ->
        Route = sample_route(#{
            namespace => <<"pertisk-eproxy">>,
            host => <<"admin.gateway.pertisk.com">>
        }),
        {ok, Result} = pertisk_gateway_reconciler:reconcile(
            [Route], [sample_gateway()], [tls_secret()]
        ),
        [Site] = maps:get(sites, Result),
        ?assertEqual(
            pertisk_ingress_tls:cert_ref(<<"pertisk-eproxy">>, <<"admin-gateway-pertisk-tls">>),
            maps:get(certificate, Site)
        ),
        ?assertEqual(1, length(maps:get(tls, Result)))
    end).

merge_results_test() ->
    A = #{sites => [#{host => <<"a">>}], backends => [], tls => []},
    B = #{sites => [#{host => <<"b">>}], backends => [], tls => []},
    M = pertisk_gateway_reconciler:merge_results(A, B),
    ?assertEqual(2, length(maps:get(sites, M))).
