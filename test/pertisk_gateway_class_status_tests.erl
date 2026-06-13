-module(pertisk_gateway_class_status_tests).

-include_lib("eunit/include/eunit.hrl").

unload_mocks() ->
    lists:foreach(
        fun(Mod) ->
            case lists:member(Mod, meck:mocked()) of
                true -> ok = pertisk_eproxy_test_helpers:unload_mocks([Mod]);
                false -> ok
            end
        end,
        [pertisk_ingress_env, pertisk_ingress_leader, pertisk_ingress_ekub]
    ).

maybe_update_skips_when_disabled_test() ->
    unload_mocks(),
    meck:new(pertisk_ingress_env, [unstick, passthrough]),
    meck:expect(pertisk_ingress_env, gateway_api_enabled, fun() -> false end),
    try
        ?assertEqual(ok, pertisk_gateway_class_status:maybe_update({api, #{}}))
    after
        unload_mocks()
    end.

maybe_update_skips_when_not_leader_test() ->
    unload_mocks(),
    meck:new(pertisk_ingress_env, [unstick, passthrough]),
    meck:new(pertisk_ingress_leader, [unstick, passthrough]),
    meck:expect(pertisk_ingress_env, gateway_api_enabled, fun() -> true end),
    meck:expect(pertisk_ingress_leader, is_leader, fun() -> false end),
    try
        ?assertEqual(ok, pertisk_gateway_class_status:maybe_update({api, #{}}))
    after
        unload_mocks()
    end.

maybe_update_patches_accepted_test() ->
    unload_mocks(),
    meck:new(pertisk_ingress_env, [unstick, passthrough]),
    meck:new(pertisk_ingress_leader, [unstick, passthrough]),
    meck:new(pertisk_ingress_ekub, [unstick]),
    meck:expect(pertisk_ingress_env, gateway_api_enabled, fun() -> true end),
    meck:expect(pertisk_ingress_leader, is_leader, fun() -> true end),
    meck:expect(pertisk_ingress_env, ingress_class, fun() -> {ok, <<"pertisk-eproxy">>} end),
    meck:expect(pertisk_ingress_ekub, merge_patch, fun(Endpoint, Body, _) ->
        ?assertMatch(<<"/apis/gateway.networking.k8s.io/v1/gatewayclasses/pertisk-eproxy/status">>, Endpoint),
        Cond = maps:get(<<"conditions">>, maps:get(<<"status">>, Body)),
        ?assertMatch([#{<<"type">> := <<"Accepted">>, <<"status">> := <<"True">>}], Cond),
        {ok, #{}}
    end),
    try
        ?assertEqual(ok, pertisk_gateway_class_status:maybe_update({api, #{}}))
    after
        unload_mocks()
    end.

maybe_update_skips_when_ingress_class_empty_test() ->
    unload_mocks(),
    meck:new(pertisk_ingress_env, [unstick, passthrough]),
    meck:new(pertisk_ingress_leader, [unstick, passthrough]),
    meck:new(pertisk_ingress_ekub, [unstick]),
    meck:expect(pertisk_ingress_env, gateway_api_enabled, fun() -> true end),
    meck:expect(pertisk_ingress_leader, is_leader, fun() -> true end),
    meck:expect(pertisk_ingress_env, ingress_class, fun() -> {ok, <<>>} end),
    meck:expect(pertisk_ingress_ekub, merge_patch, fun(_, _, _) ->
        ?assert(false, "merge_patch should not be called when ingress_class is empty")
    end),
    try
        ?assertEqual(ok, pertisk_gateway_class_status:maybe_update({api, #{}}))
    after
        unload_mocks()
    end.

maybe_update_swallows_404_patch_error_test() ->
    unload_mocks(),
    meck:new(pertisk_ingress_env, [unstick, passthrough]),
    meck:new(pertisk_ingress_leader, [unstick, passthrough]),
    meck:new(pertisk_ingress_ekub, [unstick]),
    meck:expect(pertisk_ingress_env, gateway_api_enabled, fun() -> true end),
    meck:expect(pertisk_ingress_leader, is_leader, fun() -> true end),
    meck:expect(pertisk_ingress_env, ingress_class, fun() -> {ok, <<"pertisk-eproxy">>} end),
    meck:expect(pertisk_ingress_ekub, merge_patch, fun(_, _, _) ->
        {error, #{<<"code">> => 404}}
    end),
    try
        ?assertEqual(ok, pertisk_gateway_class_status:maybe_update({api, #{}}))
    after
        unload_mocks()
    end.

maybe_update_other_patch_error_returns_ok_test() ->
    unload_mocks(),
    meck:new(pertisk_ingress_env, [unstick, passthrough]),
    meck:new(pertisk_ingress_leader, [unstick, passthrough]),
    meck:new(pertisk_ingress_ekub, [unstick]),
    meck:expect(pertisk_ingress_env, gateway_api_enabled, fun() -> true end),
    meck:expect(pertisk_ingress_leader, is_leader, fun() -> true end),
    meck:expect(pertisk_ingress_env, ingress_class, fun() -> {ok, <<"pertisk-eproxy">>} end),
    meck:expect(pertisk_ingress_ekub, merge_patch, fun(_, _, _) ->
        {error, #{<<"code">> => 500, <<"message">> => <<"server error">>}}
    end),
    try
        ?assertEqual(ok, pertisk_gateway_class_status:maybe_update({api, #{}}))
    after
        unload_mocks()
    end.
