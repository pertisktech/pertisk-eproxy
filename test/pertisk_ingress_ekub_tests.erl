-module(pertisk_ingress_ekub_tests).

-include_lib("eunit/include/eunit.hrl").

-define(SA_DIR, "/var/run/secrets/kubernetes.io/serviceaccount").

ok_or_error({ok, _}) -> true;
ok_or_error({error, _}) -> true;
ok_or_error(_) -> false.

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

with_mocked_in_cluster(Fun) ->
    meck:new(filelib, [unstick, passthrough]),
    meck:expect(filelib, is_regular, fun(P) ->
        case P of
            ?SA_DIR ++ "/token" -> true;
            ?SA_DIR ++ "/ca.crt" -> true;
            Other -> meck:passthrough([filelib, is_regular, [Other]])
        end
    end),
    meck:new(ekub_access, [unstick]),
    meck:expect(ekub_access, read, fun(Options) ->
        Server = proplists:get_value(server, Options, ""),
        {ok, #{server => Server, token => <<"token">>, namespace => <<"default">>}}
    end),
    meck:new(ekub_api, [unstick]),
    meck:expect(ekub_api, load, fun(_Access) -> {ok, mock_api} end),
    try Fun() after
        pertisk_eproxy_test_helpers:unload_mocks([filelib, ekub_access, ekub_api])
    end.

init_outside_cluster_test() ->
    case filelib:is_regular(?SA_DIR ++ "/token")
        andalso filelib:is_regular(?SA_DIR ++ "/ca.crt") of
        true ->
            ok;
        false ->
            meck:new(ekub, [unstick]),
            meck:expect(ekub, init, fun() -> {ok, {mock_api, #{}}} end),
            try
                ?assertMatch({ok, {mock_api, _}}, pertisk_ingress_ekub:init())
            after
                pertisk_eproxy_test_helpers:unload_mocks([ekub])
            end
    end.

init_in_cluster_custom_api_server_test() ->
    with_mocked_in_cluster(fun() ->
        with_env("PERTISK_K8S_API_SERVER", {set, "https://k8s.example:6443"}, fun() ->
            {ok, {mock_api, Access}} = pertisk_ingress_ekub:init(),
            ?assertEqual("https://k8s.example:6443", maps:get(server, Access))
        end)
    end).

init_in_cluster_kubernetes_service_env_test() ->
    with_mocked_in_cluster(fun() ->
        with_env("PERTISK_K8S_API_SERVER", unset, fun() ->
            with_env("KUBERNETES_SERVICE_HOST", {set, "10.96.0.1"}, fun() ->
                with_env("KUBERNETES_SERVICE_PORT_HTTPS", {set, "8443"}, fun() ->
                    {ok, {mock_api, Access}} = pertisk_ingress_ekub:init(),
                    ?assertEqual("https://10.96.0.1:8443", maps:get(server, Access))
                end)
            end)
        end)
    end).

init_in_cluster_default_api_server_test() ->
    with_mocked_in_cluster(fun() ->
        with_env("PERTISK_K8S_API_SERVER", unset, fun() ->
            with_env("KUBERNETES_SERVICE_HOST", unset, fun() ->
                with_env("KUBERNETES_SERVICE_PORT_HTTPS", unset, fun() ->
                    {ok, {mock_api, Access}} = pertisk_ingress_ekub:init(),
                    ?assertEqual("https://kubernetes.default.svc.cluster.local",
                        maps:get(server, Access))
                end)
            end)
        end)
    end).

init_in_cluster_empty_api_server_env_test() ->
    with_mocked_in_cluster(fun() ->
        with_env("PERTISK_K8S_API_SERVER", {set, ""}, fun() ->
            with_env("KUBERNETES_SERVICE_HOST", {set, "10.0.0.1"}, fun() ->
                with_env("KUBERNETES_SERVICE_PORT_HTTPS", {set, "443"}, fun() ->
                    {ok, {mock_api, Access}} = pertisk_ingress_ekub:init(),
                    ?assertEqual("https://10.0.0.1:443", maps:get(server, Access))
                end)
            end)
        end)
    end).

init_in_cluster_missing_https_port_test() ->
    with_mocked_in_cluster(fun() ->
        with_env("PERTISK_K8S_API_SERVER", unset, fun() ->
            with_env("KUBERNETES_SERVICE_HOST", {set, "10.0.0.1"}, fun() ->
                with_env("KUBERNETES_SERVICE_PORT_HTTPS", unset, fun() ->
                    {ok, {mock_api, Access}} = pertisk_ingress_ekub:init(),
                    ?assertEqual("https://10.0.0.1:443", maps:get(server, Access))
                end)
            end)
        end)
    end).

init_in_cluster_access_read_error_test() ->
    with_mocked_in_cluster(fun() ->
        meck:expect(ekub_access, read, fun(_) -> {error, denied} end),
        ?assertEqual({error, denied}, pertisk_ingress_ekub:init())
    end).

init_in_cluster_api_load_error_test() ->
    with_mocked_in_cluster(fun() ->
        meck:expect(ekub_api, load, fun(_) -> {error, bad_api} end),
        ?assertEqual({error, bad_api}, pertisk_ingress_ekub:init())
    end).

merge_patch_success_test() ->
    Access = #{server => "https://k8s.example", token => <<"tok">>},
    meck:new(hackney, [unstick, no_link]),
    meck:expect(hackney, request, fun(patch, Url, Headers, Body, _Opts) ->
        ?assertEqual(<<"https://k8s.example/api/v1/namespaces/default/status">>, Url),
        ?assertEqual(<<"application/merge-patch+json">>, proplists:get_value(<<"Content-Type">>, Headers)),
        ?assertEqual(<<"{\"status\":\"ok\"}">>, Body),
        {ok, 200, [], patch_ref}
    end),
    meck:expect(hackney, body, fun(patch_ref) -> {ok, <<"{\"status\":\"ok\"}">>} end),
    try
        ?assertMatch(
            {ok, #{<<"status">> := <<"ok">>}},
            pertisk_ingress_ekub:merge_patch(
                <<"/api/v1/namespaces/default/status">>,
                #{<<"status">> => <<"ok">>},
                {mock_api, Access}
            )
        )
    after
        pertisk_eproxy_test_helpers:unload_mocks([hackney])
    end.

merge_patch_http_error_test() ->
    Access = #{server => "https://k8s.example", token => <<"tok">>},
    meck:new(hackney, [unstick, no_link]),
    meck:expect(hackney, request, fun(patch, _, _, _, _) ->
        {ok, 409, [], patch_ref}
    end),
    meck:expect(hackney, body, fun(patch_ref) -> {ok, <<"{\"message\":\"conflict\"}">>} end),
    try
        ?assertMatch(
            {error, #{<<"message">> := <<"conflict">>}},
            pertisk_ingress_ekub:merge_patch(
                <<"/api/v1/namespaces/default/status">>,
                #{<<"status">> => <<"pending">>},
                {mock_api, Access}
            )
        )
    after
        pertisk_eproxy_test_helpers:unload_mocks([hackney])
    end.

merge_patch_request_failed_test() ->
    Access = #{server => "https://k8s.example", token => <<"tok">>},
    meck:new(hackney, [unstick, no_link]),
    meck:expect(hackney, request, fun(patch, _, _, _, _) -> {error, timeout} end),
    try
        ?assertEqual(
            {error, timeout},
            pertisk_ingress_ekub:merge_patch(
                <<"/api/v1/namespaces/default/status">>,
                #{<<"status">> => <<"pending">>},
                {mock_api, Access}
            )
        )
    after
        pertisk_eproxy_test_helpers:unload_mocks([hackney])
    end.
