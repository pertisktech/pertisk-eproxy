-module(pertisk_eproxy_admin_kubernetes_tests).

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

with_ingress_mode(Fun) ->
    with_env("PERTISK_MODE", {set, "ingress"}, Fun).

with_mock_k8s(Fun) ->
    Conn = {mock_api, mock_access},
    meck:new(pertisk_ingress_ekub, [unstick]),
    meck:expect(pertisk_ingress_ekub, init, fun() -> {ok, Conn} end),
    meck:new(ekub, [unstick]),
    meck:new(ekub_api, [unstick]),
    meck:new(ekub_core, [unstick]),
    try Fun(Conn) after
        pertisk_eproxy_test_helpers:unload_mocks([
            pertisk_ingress_ekub, ekub, ekub_api, ekub_core
        ])
    end.

sample_pod(Name, Ns) ->
    #{
        <<"metadata">> => #{
            <<"name">> => Name,
            <<"namespace">> => Ns,
            <<"creationTimestamp">> => <<"2020-01-01T00:00:00Z">>
        },
        <<"spec">> => #{
            <<"nodeName">> => <<"node-1">>,
            <<"containers">> => [
                #{
                    <<"resources">> => #{
                        <<"limits">> => #{<<"cpu">> => <<"500m">>, <<"memory">> => <<"256Mi">>}
                    }
                }
            ]
        },
        <<"status">> => #{
            <<"phase">> => <<"Running">>,
            <<"podIP">> => <<"10.0.0.1">>,
            <<"containerStatuses">> => [
                #{<<"ready">> => true, <<"restartCount">> => 0}
            ]
        }
    }.

sample_service(Name, Ns) ->
    #{
        <<"metadata">> => #{
            <<"name">> => Name,
            <<"namespace">> => Ns,
            <<"creationTimestamp">> => <<"2020-01-01T00:00:00Z">>
        },
        <<"spec">> => #{
            <<"type">> => <<"ClusterIP">>,
            <<"clusterIP">> => <<"10.96.0.1">>,
            <<"ports">> => [#{<<"port">> => 80, <<"protocol">> => <<"TCP">>, <<"name">> => <<"http">>}]
        },
        <<"status">> => #{}
    }.

sample_ingress(Name, Ns, Host) ->
    #{
        <<"metadata">> => #{
            <<"name">> => Name,
            <<"namespace">> => Ns,
            <<"creationTimestamp">> => <<"2020-01-01T00:00:00Z">>,
            <<"annotations">> => #{}
        },
        <<"spec">> => #{
            <<"ingressClassName">> => <<"pertisk-eproxy">>,
            <<"rules">> => [
                #{
                    <<"host">> => Host,
                    <<"http">> => #{
                        <<"paths">> => [
                            #{
                                <<"path">> => <<"/">>,
                                <<"pathType">> => <<"Prefix">>,
                                <<"backend">> => #{
                                    <<"service">> => #{
                                        <<"name">> => <<"web">>,
                                        <<"port">> => #{<<"number">> => 80}
                                    }
                                }
                            }
                        ]
                    }
                }
            ],
            <<"tls">> => [#{<<"secretName">> => <<"tls-secret">>}]
        }
    }.

available_follows_ingress_mode_test() ->
    with_ingress_mode(fun() ->
        ?assert(pertisk_eproxy_admin_kubernetes:available())
    end),
    with_env("PERTISK_MODE", unset, fun() ->
        ?assertNot(pertisk_eproxy_admin_kubernetes:available())
    end).

not_available_outside_ingress_mode_test() ->
    with_env("PERTISK_MODE", unset, fun() ->
        ?assertEqual({error, not_available}, pertisk_eproxy_admin_kubernetes:namespaces())
    end).

services_requires_namespace_test() ->
    with_ingress_mode(fun() ->
        with_mock_k8s(fun(_Conn) ->
            ?assertMatch({error, _}, pertisk_eproxy_admin_kubernetes:services(<<>>))
        end)
    end).

namespaces_list_test() ->
    with_ingress_mode(fun() ->
        with_mock_k8s(fun(_Conn) ->
            meck:expect(ekub, read, fun(namespace, ConnArg) ->
                ?assertEqual({mock_api, mock_access}, ConnArg),
                {ok, [#{<<"metadata">> => #{<<"name">> => <<"default">>, <<"creationTimestamp">> => null}}]}
            end),
            ?assertMatch({ok, [#{name := <<"default">>}]}, pertisk_eproxy_admin_kubernetes:namespaces())
        end)
    end).

pods_list_test() ->
    with_ingress_mode(fun() ->
        with_env("PERTISK_K8S_POD_NAME", {set, "pertisk-eproxy"}, fun() ->
            with_mock_k8s(fun(_Conn) ->
                meck:expect(ekub_api, endpoint, fun
                    ({<<"">>, <<"v1">>}, pod, <<"default">>, "", _) ->
                        <<"/api/v1/namespaces/default/pods">>;
                    ({<<"metrics.k8s.io">>, _}, pod, <<"default">>, "", _) ->
                        <<"/apis/metrics.k8s.io/v1beta1/namespaces/default/pods">>;
                    (_, _, _, _, _) ->
                        <<>>
                end),
                meck:expect(ekub_core, http_request, fun
                    (<<"/api/v1/namespaces/default/pods">>, _, _) ->
                        {ok, #{<<"items">> => [sample_pod(<<"pertisk-eproxy-abc">>, <<"default">>)]}};
                    (<<"/apis/metrics.k8s.io/v1beta1/namespaces/default/pods">>, _, _) ->
                        {ok, #{
                            <<"items">> => [
                                #{
                                    <<"metadata">> => #{
                                        <<"name">> => <<"pertisk-eproxy-abc">>,
                                        <<"namespace">> => <<"default">>
                                    },
                                    <<"containers">> => [
                                        #{
                                            <<"usage">> => #{
                                                <<"cpu">> => <<"100m">>,
                                                <<"memory">> => <<"64Mi">>
                                            }
                                        }
                                    ]
                                }
                            ]
                        }}
                end),
                {ok, [Row | _]} = pertisk_eproxy_admin_kubernetes:pods(<<"default">>),
                ?assertEqual(<<"pertisk-eproxy-abc">>, maps:get(<<"name">>, Row))
            end)
        end)
    end).

services_in_namespace_test() ->
    with_ingress_mode(fun() ->
        with_mock_k8s(fun(_Conn) ->
            meck:expect(ekub, read, fun(service, <<"apps">>, [], ConnArg) ->
                ?assertEqual({mock_api, mock_access}, ConnArg),
                {ok, #{<<"items">> => [sample_service(<<"web">>, <<"apps">>)]}}
            end),
            {ok, [Row | _]} = pertisk_eproxy_admin_kubernetes:services(<<"apps">>),
            ?assertEqual(<<"web">>, maps:get(name, Row))
        end)
    end).

tls_secrets_list_test() ->
    with_ingress_mode(fun() ->
        with_mock_k8s(fun(_Conn) ->
            meck:expect(ekub, read, fun
                (secret, _Query, ConnArg) when ConnArg =:= {mock_api, mock_access} ->
                    {ok, #{<<"items">> => []}};
                (ingress, _Query, ConnArg) ->
                    ?assertEqual({mock_api, mock_access}, ConnArg),
                    {ok, #{<<"items">> => [sample_ingress(<<"app">>, <<"default">>, <<"app.example">>)]}}
            end),
            {ok, [Row | _]} = pertisk_eproxy_admin_kubernetes:tls_secrets(<<>>),
            ?assertEqual(<<"tls-secret">>, maps:get(name, Row))
        end)
    end).

list_ingresses_test() ->
    with_ingress_mode(fun() ->
        with_mock_k8s(fun(_Conn) ->
            meck:expect(ekub, read, fun(ingress, _Query, ConnArg) ->
                ?assertEqual({mock_api, mock_access}, ConnArg),
                {ok, #{<<"items">> => [sample_ingress(<<"app">>, <<"default">>, <<"app.example">>)]}}
            end),
            {ok, [Row | _]} = pertisk_eproxy_admin_kubernetes:list_ingresses(),
            ?assertEqual(<<"app">>, maps:get(name, Row))
        end)
    end).

get_ingress_test() ->
    with_ingress_mode(fun() ->
        with_mock_k8s(fun(_Conn) ->
            meck:expect(ekub, read, fun(ingress, <<"default">>, <<"app">>, ConnArg) ->
                ?assertEqual({mock_api, mock_access}, ConnArg),
                {ok, sample_ingress(<<"app">>, <<"default">>, <<"app.example">>)}
            end),
            ?assertMatch({ok, #{host := <<"app.example">>}},
                pertisk_eproxy_admin_kubernetes:get_ingress(<<"default">>, <<"app">>))
        end)
    end).

create_ingress_test() ->
    with_ingress_mode(fun() ->
        with_mock_k8s(fun(_Conn) ->
            meck:expect(ekub, create, fun(Resource, Ns, ConnArg) ->
                ?assertEqual(<<"default">>, Ns),
                ?assertEqual({mock_api, mock_access}, ConnArg),
                ?assertEqual(<<"demo">>, maps:get(<<"name">>, maps:get(<<"metadata">>, Resource))),
                {ok, Resource}
            end),
            Body = #{
                <<"name">> => <<"demo">>,
                <<"host">> => <<"demo.example">>,
                <<"service_namespace">> => <<"default">>,
                <<"service_name">> => <<"web">>,
                <<"service_port">> => 80,
                <<"routes">> => [
                    #{
                        <<"path">> => <<"/">>,
                        <<"path_type">> => <<"Prefix">>,
                        <<"service_name">> => <<"web">>,
                        <<"service_port">> => 80
                    }
                ]
            },
            ?assertMatch({ok, #{message := <<"Ingress created">>}},
                pertisk_eproxy_admin_kubernetes:create_ingress(Body))
        end)
    end).

update_ingress_test() ->
    with_ingress_mode(fun() ->
        with_mock_k8s(fun(_Conn) ->
            meck:expect(ekub, read, fun(ingress, <<"default">>, <<"app">>, ConnArg) ->
                ?assertEqual({mock_api, mock_access}, ConnArg),
                {ok, sample_ingress(<<"app">>, <<"default">>, <<"app.example">>)}
            end),
            meck:expect(ekub, replace, fun(Resource, Ns, ConnArg) ->
                ?assertEqual(<<"default">>, Ns),
                ?assertEqual({mock_api, mock_access}, ConnArg),
                ?assertEqual(<<"app">>, maps:get(<<"name">>, maps:get(<<"metadata">>, Resource))),
                {ok, Resource}
            end),
            Body = #{
                <<"name">> => <<"app">>,
                <<"host">> => <<"updated.example">>,
                <<"service_namespace">> => <<"default">>,
                <<"service_name">> => <<"web">>,
                <<"service_port">> => 80,
                <<"routes">> => [
                    #{
                        <<"path">> => <<"/">>,
                        <<"path_type">> => <<"Prefix">>,
                        <<"service_name">> => <<"web">>,
                        <<"service_port">> => 80
                    }
                ]
            },
            ?assertMatch({ok, #{message := <<"Ingress updated">>}},
                pertisk_eproxy_admin_kubernetes:update_ingress(<<"default">>, <<"app">>, Body))
        end)
    end).

pods_forbidden_returns_empty_test() ->
    with_ingress_mode(fun() ->
        with_mock_k8s(fun(_Conn) ->
            meck:expect(ekub_api, endpoint, fun(_, pod, _, _, _) -> <<"/pods">> end),
            meck:expect(ekub_core, http_request, fun(_, _, _) -> {error, #{<<"code">> => 403}} end),
            ?assertEqual({ok, []}, pertisk_eproxy_admin_kubernetes:pods(<<"default">>))
        end)
    end).

delete_ingress_test() ->
    with_ingress_mode(fun() ->
        with_mock_k8s(fun(_Conn) ->
            meck:expect(ekub, delete, fun(ingress, <<"default">>, <<"gone">>, ConnArg) ->
                ?assertEqual({mock_api, mock_access}, ConnArg),
                {ok, deleted}
            end),
            ?assertMatch({ok, #{message := <<"Ingress deleted">>}},
                pertisk_eproxy_admin_kubernetes:delete_ingress(<<"default">>, <<"gone">>))
        end)
    end).

namespaces_ekub_error_test() ->
    with_ingress_mode(fun() ->
        with_mock_k8s(fun(_Conn) ->
            meck:expect(ekub, read, fun(namespace, _) -> {error, #{<<"code">> => 500}} end),
            ?assertMatch({error, _}, pertisk_eproxy_admin_kubernetes:namespaces())
        end)
    end).

ekub_init_error_test() ->
    with_ingress_mode(fun() ->
        meck:new(pertisk_ingress_ekub, [unstick]),
        meck:expect(pertisk_ingress_ekub, init, fun() -> {error, no_cluster} end),
        try
            ?assertMatch({error, no_cluster}, pertisk_eproxy_admin_kubernetes:namespaces())
        after
            pertisk_eproxy_test_helpers:unload_mocks([pertisk_ingress_ekub])
        end
    end).

tls_secrets_fallback_from_ingress_test() ->
    with_ingress_mode(fun() ->
        with_mock_k8s(fun(_Conn) ->
            meck:expect(ekub, read, fun
                (secret, _, _) ->
                    {ok, #{<<"items">> => []}};
                (ingress, _, _) ->
                    {ok, #{<<"items">> => [sample_ingress(<<"app">>, <<"default">>, <<"app.example">>)]}}
            end),
            {ok, [Row | _]} = pertisk_eproxy_admin_kubernetes:tls_secrets(<<>>),
            ?assertEqual(<<"tls-secret">>, maps:get(name, Row))
        end)
    end).

create_ingress_missing_host_test() ->
    with_ingress_mode(fun() ->
        with_mock_k8s(fun(_Conn) ->
            ?assertMatch({error, _},
                pertisk_eproxy_admin_kubernetes:create_ingress(#{
                    <<"name">> => <<"demo">>,
                    <<"service_namespace">> => <<"default">>,
                    <<"service_name">> => <<"web">>,
                    <<"service_port">> => 80
                }))
        end)
    end).

get_ingress_not_found_test() ->
    with_ingress_mode(fun() ->
        with_mock_k8s(fun(_Conn) ->
            meck:expect(ekub, read, fun(ingress, _, _, _) -> {error, #{<<"code">> => 404}} end),
            ?assertMatch({error, _},
                pertisk_eproxy_admin_kubernetes:get_ingress(<<"default">>, <<"missing">>))
        end)
    end).

list_ingresses_error_test() ->
    with_ingress_mode(fun() ->
        with_mock_k8s(fun(_Conn) ->
            meck:expect(ekub, read, fun(ingress, _, _) -> {error, #{<<"message">> => <<"fail">>}} end),
            ?assertMatch({error, _}, pertisk_eproxy_admin_kubernetes:list_ingresses())
        end)
    end).

pods_endpoint_not_found_test() ->
    with_ingress_mode(fun() ->
        with_mock_k8s(fun(_Conn) ->
            meck:expect(ekub_api, endpoint, fun(_, _, _, _, _) -> <<>> end),
            ?assertMatch({error, _}, pertisk_eproxy_admin_kubernetes:pods(<<"default">>))
        end)
    end).

services_ekub_error_test() ->
    with_ingress_mode(fun() ->
        with_mock_k8s(fun(_Conn) ->
            meck:expect(ekub, read, fun(service, _, _, _) -> {error, #{<<"code">> => 503}} end),
            ?assertMatch({error, _}, pertisk_eproxy_admin_kubernetes:services(<<"apps">>))
        end)
    end).

update_ingress_missing_host_test() ->
    with_ingress_mode(fun() ->
        with_mock_k8s(fun(_Conn) ->
            meck:expect(ekub, read, fun(ingress, <<"default">>, <<"app">>, _) ->
                {ok, sample_ingress(<<"app">>, <<"default">>, <<"app.example">>)}
            end),
            ?assertMatch({error, _},
                pertisk_eproxy_admin_kubernetes:update_ingress(<<"default">>, <<"app">>, #{
                    <<"service_namespace">> => <<"default">>,
                    <<"service_name">> => <<"web">>,
                    <<"service_port">> => 80
                }))
        end)
    end).

delete_ingress_not_found_still_ok_test() ->
    with_ingress_mode(fun() ->
        with_mock_k8s(fun(_Conn) ->
            meck:expect(ekub, delete, fun(ingress, <<"default">>, <<"gone">>, _) ->
                {error, #{<<"code">> => 404}}
            end),
            ?assertMatch({ok, #{message := <<"Ingress deleted">>}},
                pertisk_eproxy_admin_kubernetes:delete_ingress(<<"default">>, <<"gone">>))
        end)
    end).

delete_ingress_error_test() ->
    with_ingress_mode(fun() ->
        with_mock_k8s(fun(_Conn) ->
            meck:expect(ekub, delete, fun(ingress, _, _, _) ->
                {error, #{<<"code">> => 409, <<"message">> => <<"conflict">>}}
            end),
            ?assertMatch({error, _},
                pertisk_eproxy_admin_kubernetes:delete_ingress(<<"default">>, <<"app">>))
        end)
    end).

create_ingress_ekub_error_test() ->
    with_ingress_mode(fun() ->
        with_mock_k8s(fun(_Conn) ->
            meck:expect(ekub, create, fun(_, _, _) -> {error, #{<<"code">> => 422}} end),
            Body = #{
                <<"name">> => <<"demo">>,
                <<"host">> => <<"demo.example">>,
                <<"service_namespace">> => <<"default">>,
                <<"service_name">> => <<"web">>,
                <<"service_port">> => 80,
                <<"routes">> => [
                    #{
                        <<"path">> => <<"/">>,
                        <<"path_type">> => <<"Prefix">>,
                        <<"service_name">> => <<"web">>,
                        <<"service_port">> => 80
                    }
                ]
            },
            ?assertMatch({error, _}, pertisk_eproxy_admin_kubernetes:create_ingress(Body))
        end)
    end).

pods_metrics_forbidden_returns_empty_test() ->
    with_ingress_mode(fun() ->
        with_env("PERTISK_K8S_POD_NAME", {set, "pertisk-eproxy"}, fun() ->
            with_mock_k8s(fun(_Conn) ->
                meck:expect(ekub_api, endpoint, fun
                    ({<<"">>, <<"v1">>}, pod, <<"default">>, "", _) ->
                        <<"/api/v1/namespaces/default/pods">>;
                    (_, _, _, _, _) ->
                        <<>>
                end),
                meck:expect(ekub_core, http_request, fun
                    (<<"/api/v1/namespaces/default/pods">>, _, _) ->
                        {ok, #{<<"items">> => [sample_pod(<<"pertisk-eproxy-abc">>, <<"default">>)]}};
                    (_, _, _) ->
                        {error, #{<<"code">> => 403}}
                end),
                {ok, [Row | _]} = pertisk_eproxy_admin_kubernetes:pods(<<"default">>),
                ?assertEqual(null, maps:get(<<"cpu_usage_millicores">>, Row))
            end)
        end)
    end).

tls_secrets_in_namespace_test() ->
    with_ingress_mode(fun() ->
        with_mock_k8s(fun(_Conn) ->
            meck:expect(ekub, read, fun
                (secret, <<"apps">>, [], _) ->
                    {ok, #{
                        <<"items">> => [
                            #{
                                <<"type">> => <<"kubernetes.io/tls">>,
                                <<"metadata">> => #{
                                    <<"name">> => <<"site-tls">>,
                                    <<"namespace">> => <<"apps">>
                                },
                                <<"data">> => #{
                                    <<"tls.crt">> => <<"Y2VydA==">>,
                                    <<"tls.key">> => <<"a2V5">>
                                }
                            }
                        ]
                    }};
                (_, _, _, _) ->
                    {error, not_used}
            end),
            {ok, [Row | _]} = pertisk_eproxy_admin_kubernetes:tls_secrets(<<"apps">>),
            ?assertEqual(<<"site-tls">>, maps:get(name, Row)),
            ?assertEqual(<<"apps">>, maps:get(namespace, Row))
        end)
    end).
