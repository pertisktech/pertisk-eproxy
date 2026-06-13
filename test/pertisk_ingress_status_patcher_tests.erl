-module(pertisk_ingress_status_patcher_tests).

-include_lib("eunit/include/eunit.hrl").

unload_mocks() ->
    pertisk_eproxy_test_helpers:unload_mocks([
        pertisk_ingress_leader, pertisk_ingress_env, ekub
    ]).

sample_ingress(Opts) ->
    #{
        <<"metadata">> => #{
            <<"namespace">> => maps:get(namespace, Opts, <<"default">>),
            <<"name">> => maps:get(name, Opts, <<"web">>)
        },
        <<"spec">> => maps:get(spec, Opts, #{<<"rules">> => []})
    }.

maybe_update_skips_when_not_leader_test() ->
    unload_mocks(),
    meck:new(pertisk_ingress_leader, [unstick, passthrough]),
    meck:expect(pertisk_ingress_leader, is_leader, fun() -> false end),
    try
        ?assertEqual(
            ok,
            pertisk_ingress_status_patcher:maybe_update([sample_ingress(#{})], {api, #{}})
        )
    after
        unload_mocks()
    end.

maybe_update_patches_programmed_test() ->
    unload_mocks(),
    meck:new(pertisk_ingress_leader, [unstick, passthrough]),
    meck:new(pertisk_ingress_env, [unstick, passthrough]),
    meck:new(ekub, [unstick]),
    meck:expect(pertisk_ingress_leader, is_leader, fun() -> true end),
    meck:expect(pertisk_ingress_env, publish_service_name, fun() -> error end),
    meck:expect(ekub, patch, fun({ingress, <<"status">>}, Ns, Name, Body, _) ->
        ?assertEqual(<<"default">>, Ns),
        ?assertEqual(<<"web">>, Name),
        Cond = maps:get(<<"conditions">>, maps:get(<<"status">>, Body)),
        ?assertMatch([#{<<"reason">> := <<"Programmed">>, <<"status">> := <<"True">>}], Cond),
        {ok, #{}}
    end),
    try
        ?assertEqual(
            ok,
            pertisk_ingress_status_patcher:maybe_update([sample_ingress(#{})], {api, #{}})
        )
    after
        unload_mocks()
    end.

maybe_update_resource_backend_condition_test() ->
    unload_mocks(),
    meck:new(pertisk_ingress_leader, [unstick, passthrough]),
    meck:new(pertisk_ingress_env, [unstick, passthrough]),
    meck:new(ekub, [unstick]),
    Spec = #{
        <<"rules">> => [
            #{
                <<"http">> => #{
                    <<"paths">> => [
                        #{<<"backend">> => #{<<"resource">> => #{<<"name">> => <<"svc">>}}}
                    ]
                }
            }
        ]
    },
    meck:expect(pertisk_ingress_leader, is_leader, fun() -> true end),
    meck:expect(pertisk_ingress_env, publish_service_name, fun() -> error end),
    meck:expect(ekub, patch, fun(_, _, _, Body, _) ->
        Cond = maps:get(<<"conditions">>, maps:get(<<"status">>, Body)),
        ?assertMatch(
            [#{<<"reason">> := <<"UnsupportedBackendResource">>, <<"status">> := <<"False">>}],
            Cond
        ),
        {ok, #{}}
    end),
    try
        Ingress = sample_ingress(#{spec => Spec}),
        ?assertEqual(ok, pertisk_ingress_status_patcher:maybe_update([Ingress], {api, #{}}))
    after
        unload_mocks()
    end.

maybe_update_load_balancer_rows_test() ->
    unload_mocks(),
    meck:new(pertisk_ingress_leader, [unstick, passthrough]),
    meck:new(pertisk_ingress_env, [unstick, passthrough]),
    meck:new(ekub, [unstick]),
    Svc = #{
        <<"status">> => #{
            <<"loadBalancer">> => #{
                <<"ingress">> => [#{<<"ip">> => <<"203.0.113.10">>}]
            }
        }
    },
    meck:expect(pertisk_ingress_leader, is_leader, fun() -> true end),
    meck:expect(pertisk_ingress_env, publish_service_name, fun() -> {ok, <<"ingress-lb">>} end),
    meck:expect(pertisk_ingress_env, leader_namespace, fun() -> <<"ingress-ns">> end),
    meck:expect(ekub, read, fun(service, <<"ingress-ns">>, <<"ingress-lb">>, _) ->
        {ok, Svc}
    end),
    meck:expect(ekub, patch, fun(_, _, _, Body, _) ->
        Rows = maps:get(
            <<"ingress">>,
            maps:get(<<"loadBalancer">>, maps:get(<<"status">>, Body))
        ),
        ?assertEqual([#{<<"ip">> => <<"203.0.113.10">>}], Rows),
        {ok, #{}}
    end),
    try
        ?assertEqual(
            ok,
            pertisk_ingress_status_patcher:maybe_update([sample_ingress(#{})], {api, #{}})
        )
    after
        unload_mocks()
    end.

maybe_update_patch_404_test() ->
    unload_mocks(),
    meck:new(pertisk_ingress_leader, [unstick, passthrough]),
    meck:new(pertisk_ingress_env, [unstick, passthrough]),
    meck:new(ekub, [unstick]),
    meck:expect(pertisk_ingress_leader, is_leader, fun() -> true end),
    meck:expect(pertisk_ingress_env, publish_service_name, fun() -> error end),
    meck:expect(ekub, patch, fun(_, _, _, _, _) ->
        {error, #{<<"code">> => 404}}
    end),
    try
        ?assertEqual(
            ok,
            pertisk_ingress_status_patcher:maybe_update([sample_ingress(#{})], {api, #{}})
        )
    after
        unload_mocks()
    end.

maybe_update_patch_error_test() ->
    unload_mocks(),
    meck:new(pertisk_ingress_leader, [unstick, passthrough]),
    meck:new(pertisk_ingress_env, [unstick, passthrough]),
    meck:new(ekub, [unstick]),
    meck:expect(pertisk_ingress_leader, is_leader, fun() -> true end),
    meck:expect(pertisk_ingress_env, publish_service_name, fun() -> error end),
    meck:expect(ekub, patch, fun(_, _, _, _, _) ->
        {error, #{<<"code">> => 500, <<"message">> => <<"fail">>}}
    end),
    try
        ?assertEqual(
            ok,
            pertisk_ingress_status_patcher:maybe_update([sample_ingress(#{})], {api, #{}})
        )
    after
        unload_mocks()
    end.

maybe_update_non_list_ingresses_test() ->
    ?assertEqual(ok, pertisk_ingress_status_patcher:maybe_update(not_a_list, {api, #{}})).
