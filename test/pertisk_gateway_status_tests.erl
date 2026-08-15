-module(pertisk_gateway_status_tests).

-include_lib("eunit/include/eunit.hrl").

gateway_address_from_ip_test() ->
    Addrs = pertisk_gateway_status:row_to_address(#{<<"ip">> => <<"192.0.2.10">>}),
    ?assertEqual([#{<<"type">> => <<"IPAddress">>, <<"value">> => <<"192.0.2.10">>}], Addrs).

gateway_address_from_hostname_test() ->
    Addrs = pertisk_gateway_status:row_to_address(#{<<"hostname">> => <<"lb.example.com">>}),
    ?assertEqual([#{<<"type">> => <<"Hostname">>, <<"value">> => <<"lb.example.com">>}], Addrs).

gateway_address_skips_empty_test() ->
    ?assertEqual([], pertisk_gateway_status:row_to_address(#{<<"ip">> => <<>>})).

unload_mocks() ->
    pertisk_eproxy_test_helpers:unload_mocks([
        pertisk_ingress_env, pertisk_ingress_leader, pertisk_ingress_ekub, ekub, ekub_core
    ]).

sample_gateway(Opts) ->
    #{
        <<"metadata">> => #{
            <<"namespace">> => maps:get(namespace, Opts, <<"default">>),
            <<"name">> => maps:get(name, Opts, <<"gw">>)
        },
        <<"spec">> => #{
            <<"gatewayClassName">> => maps:get(class, Opts, <<"pertisk-eproxy">>)
        }
    }.

maybe_update_skips_when_gateway_api_disabled_test() ->
    unload_mocks(),
    meck:new(pertisk_ingress_env, [unstick, passthrough]),
    meck:expect(pertisk_ingress_env, gateway_api_enabled, fun() -> false end),
    try
        ?assertEqual(ok, pertisk_gateway_status:maybe_update({api, #{}}))
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
        ?assertEqual(ok, pertisk_gateway_status:maybe_update({api, #{}}))
    after
        unload_mocks()
    end.

maybe_update_patches_matching_gateway_test() ->
    unload_mocks(),
    Conn = {api, #{}},
    Gateway = sample_gateway(#{}),
    meck:new(pertisk_ingress_env, [unstick, passthrough]),
    meck:new(pertisk_ingress_leader, [unstick, passthrough]),
    meck:new(pertisk_ingress_ekub, [unstick]),
    meck:new(ekub_core, [unstick]),
    meck:expect(pertisk_ingress_env, gateway_api_enabled, fun() -> true end),
    meck:expect(pertisk_ingress_leader, is_leader, fun() -> true end),
    meck:expect(pertisk_ingress_env, ingress_class, fun() -> {ok, <<"pertisk-eproxy">>} end),
    meck:expect(pertisk_ingress_env, namespace, fun() -> <<"default">> end),
    meck:expect(pertisk_ingress_env, publish_service_name, fun() -> error end),
    meck:expect(ekub_core, http_request, fun(_Endpoint, _Query, _Conn) ->
        {ok, #{<<"items">> => [Gateway]}}
    end),
    meck:expect(pertisk_ingress_ekub, merge_patch, fun(Endpoint, Body, ConnArg) ->
        ?assertEqual(Conn, ConnArg),
        ?assertMatch(<<"/apis/gateway.networking.k8s.io/v1/namespaces/default/gateways/gw/status">>, Endpoint),
        Cond = maps:get(<<"conditions">>, maps:get(<<"status">>, Body)),
        ?assertMatch(
            [#{<<"type">> := <<"Accepted">>, <<"status">> := <<"True">>},
             #{<<"type">> := <<"Programmed">>, <<"status">> := <<"True">>}],
            Cond
        ),
        {ok, #{}}
    end),
    try
        ?assertEqual(ok, pertisk_gateway_status:maybe_update(Conn))
    after
        unload_mocks()
    end.

maybe_update_skips_non_matching_class_test() ->
    unload_mocks(),
    Conn = {api, #{}},
    Gateway = sample_gateway(#{class => <<"other-class">>}),
    meck:new(pertisk_ingress_env, [unstick, passthrough]),
    meck:new(pertisk_ingress_leader, [unstick, passthrough]),
    meck:new(ekub_core, [unstick]),
    meck:expect(pertisk_ingress_env, gateway_api_enabled, fun() -> true end),
    meck:expect(pertisk_ingress_leader, is_leader, fun() -> true end),
    meck:expect(pertisk_ingress_env, ingress_class, fun() -> {ok, <<"pertisk-eproxy">>} end),
    meck:expect(pertisk_ingress_env, namespace, fun() -> <<"default">> end),
    meck:expect(ekub_core, http_request, fun(_, _, _) ->
        {ok, #{<<"items">> => [Gateway]}}
    end),
    try
        ?assertEqual(ok, pertisk_gateway_status:maybe_update(Conn))
    after
        unload_mocks()
    end.

maybe_update_list_gateways_404_test() ->
    unload_mocks(),
    Conn = {api, #{}},
    meck:new(pertisk_ingress_env, [unstick, passthrough]),
    meck:new(pertisk_ingress_leader, [unstick, passthrough]),
    meck:new(ekub_core, [unstick]),
    meck:expect(pertisk_ingress_env, gateway_api_enabled, fun() -> true end),
    meck:expect(pertisk_ingress_leader, is_leader, fun() -> true end),
    meck:expect(pertisk_ingress_env, ingress_class, fun() -> all end),
    meck:expect(pertisk_ingress_env, namespace, fun() -> all_namespaces end),
    meck:expect(ekub_core, http_request, fun(_, _, _) ->
        {error, #{<<"code">> => 404}}
    end),
    try
        ?assertEqual(ok, pertisk_gateway_status:maybe_update(Conn))
    after
        unload_mocks()
    end.

maybe_update_patch_404_test() ->
    unload_mocks(),
    Conn = {api, #{}},
    Gateway = sample_gateway(#{}),
    meck:new(pertisk_ingress_env, [unstick, passthrough]),
    meck:new(pertisk_ingress_leader, [unstick, passthrough]),
    meck:new(pertisk_ingress_ekub, [unstick]),
    meck:new(ekub_core, [unstick]),
    meck:expect(pertisk_ingress_env, gateway_api_enabled, fun() -> true end),
    meck:expect(pertisk_ingress_leader, is_leader, fun() -> true end),
    meck:expect(pertisk_ingress_env, ingress_class, fun() -> all end),
    meck:expect(pertisk_ingress_env, namespace, fun() -> <<"default">> end),
    meck:expect(pertisk_ingress_env, publish_service_name, fun() -> error end),
    meck:expect(ekub_core, http_request, fun(_, _, _) ->
        {ok, #{<<"items">> => [Gateway]}}
    end),
    meck:expect(pertisk_ingress_ekub, merge_patch, fun(_, _, _) ->
        {error, #{<<"code">> => 404}}
    end),
    try
        ?assertEqual(ok, pertisk_gateway_status:maybe_update(Conn))
    after
        unload_mocks()
    end.

maybe_update_load_balancer_hostname_test() ->
    unload_mocks(),
    Conn = {api, #{}},
    Gateway = sample_gateway(#{}),
    Svc = #{
        <<"status">> => #{
            <<"loadBalancer">> => #{
                <<"ingress">> => [#{<<"hostname">> => <<"lb.example.com">>}]
            }
        }
    },
    meck:new(pertisk_ingress_env, [unstick, passthrough]),
    meck:new(pertisk_ingress_leader, [unstick, passthrough]),
    meck:new(pertisk_ingress_ekub, [unstick]),
    meck:new(ekub, [unstick]),
    meck:new(ekub_core, [unstick]),
    meck:expect(pertisk_ingress_env, gateway_api_enabled, fun() -> true end),
    meck:expect(pertisk_ingress_leader, is_leader, fun() -> true end),
    meck:expect(pertisk_ingress_env, ingress_class, fun() -> all end),
    meck:expect(pertisk_ingress_env, namespace, fun() -> <<"default">> end),
    meck:expect(pertisk_ingress_env, publish_service_name, fun() -> {ok, <<"svc-lb">>} end),
    meck:expect(pertisk_ingress_env, leader_namespace, fun() -> <<"ns">> end),
    meck:expect(ekub, read, fun(service, <<"ns">>, <<"svc-lb">>, _) -> {ok, Svc} end),
    meck:expect(ekub_core, http_request, fun(_, _, _) ->
        {ok, #{<<"items">> => [Gateway]}}
    end),
    meck:expect(pertisk_ingress_ekub, merge_patch, fun(_, Body, _) ->
        Addrs = maps:get(<<"addresses">>, maps:get(<<"status">>, Body)),
        ?assertEqual(
            [#{<<"type">> => <<"Hostname">>, <<"value">> => <<"lb.example.com">>}],
            Addrs
        ),
        {ok, #{}}
    end),
    try
        ?assertEqual(ok, pertisk_gateway_status:maybe_update(Conn))
    after
        unload_mocks()
    end.
