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

reconcile_httproute_test() ->
    {ok, Result} = pertisk_gateway_reconciler:reconcile([sample_route(#{})]),
    [Site] = maps:get(sites, Result),
    ?assertEqual(<<"api.example.com">>, maps:get(host, Site)),
    [Backend] = maps:get(backends, Result),
    Addr = maps:get(addr, hd(maps:get(upstreams, Backend))),
    ?assertNotEqual(nomatch, binary:match(Addr, <<"backend.default.svc.cluster.local:8080">>)).

merge_results_test() ->
    A = #{sites => [#{host => <<"a">>}], backends => [], tls => []},
    B = #{sites => [#{host => <<"b">>}], backends => [], tls => []},
    M = pertisk_gateway_reconciler:merge_results(A, B),
    ?assertEqual(2, length(maps:get(sites, M))).
