-module(pertisk_ingress_env_tests).

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

ingress_mode_from_env_test() ->
    with_env("PERTISK_MODE", {set, "ingress"}, fun() ->
        ?assert(pertisk_ingress_env:ingress_mode())
    end),
    with_env("PERTISK_MODE", {set, "proxy"}, fun() ->
        ?assertNot(pertisk_ingress_env:ingress_mode())
    end),
    with_env("PERTISK_MODE", unset, fun() ->
        ?assertNot(pertisk_ingress_env:ingress_mode())
    end).

enabled_follows_ingress_mode_test() ->
    with_env("PERTISK_MODE", {set, "ingress"}, fun() ->
        ?assert(pertisk_ingress_env:enabled())
    end).

ingress_class_defaults_test() ->
    with_env("PERTISK_K8S_INGRESS_CLASS", unset, fun() ->
        ?assertEqual({ok, <<"pertisk-eproxy">>}, pertisk_ingress_env:ingress_class())
    end).

ingress_class_wildcard_test() ->
    with_env("PERTISK_K8S_INGRESS_CLASS", {set, "*"}, fun() ->
        ?assertEqual(all, pertisk_ingress_env:ingress_class())
    end).

namespace_all_when_unset_test() ->
    with_env("PERTISK_K8S_NAMESPACE", unset, fun() ->
        ?assertEqual(all_namespaces, pertisk_ingress_env:namespace())
    end).

leader_lease_defaults_test() ->
    with_env("PERTISK_K8S_LEADER_NAME", unset, fun() ->
        ?assertEqual(<<"pertisk-eproxy-leader">>, pertisk_ingress_env:leader_lease_name())
    end).

lease_duration_defaults_test() ->
    ?assertEqual(15, pertisk_ingress_env:lease_duration_seconds()),
    ?assertEqual(5, pertisk_ingress_env:renew_interval_seconds()).

timing_defaults_test() ->
    ?assertEqual(5000, pertisk_ingress_env:watch_backoff_ms()),
    ?assertEqual(30000, pertisk_ingress_env:reconcile_interval_ms()).

k8s_tls_dir_default_test() ->
    with_env("PERTISK_K8S_TLS_DIR", unset, fun() ->
        ?assertEqual("data/k8s-tls", pertisk_ingress_env:k8s_tls_dir())
    end).

holder_id_from_hostname_test() ->
    with_env("HOSTNAME", {set, "pod-abc"}, fun() ->
        ?assertEqual(<<"pod-abc">>, pertisk_ingress_env:holder_id())
    end).

controller_pod_name_default_test() ->
    with_env("PERTISK_K8S_CONTROLLER_NAME", unset, fun() ->
        ?assertEqual(<<"pertisk-eproxy">>, pertisk_ingress_env:controller_pod_name())
    end).

enabled_from_env_flag_test() ->
    with_env("PERTISK_MODE", unset, fun() ->
        with_env("PERTISK_K8S_INGRESS_ENABLED", {set, "true"}, fun() ->
            ?assert(pertisk_ingress_env:enabled())
        end),
        with_env("PERTISK_K8S_INGRESS_ENABLED", {set, "0"}, fun() ->
            ?assertNot(pertisk_ingress_env:enabled())
        end)
    end).

namespace_from_env_test() ->
    with_env("PERTISK_K8S_NAMESPACE", {set, "  my-ns  "}, fun() ->
        ?assertEqual(<<"my-ns">>, pertisk_ingress_env:namespace())
    end).

ingress_class_custom_test() ->
    with_env("PERTISK_K8S_INGRESS_CLASS", {set, "custom"}, fun() ->
        ?assertEqual({ok, <<"custom">>}, pertisk_ingress_env:ingress_class())
    end).

leader_election_flag_test() ->
    with_env("PERTISK_K8S_LEADER_ELECTION_ENABLED", {set, "false"}, fun() ->
        ?assertNot(pertisk_ingress_env:leader_election_enabled())
    end),
    with_env("PERTISK_K8S_LEADER_ELECTION_ENABLED", {set, "yes"}, fun() ->
        ?assert(pertisk_ingress_env:leader_election_enabled())
    end).

leader_namespace_from_env_test() ->
    with_env("PERTISK_K8S_LEADER_NAMESPACE", {set, "leader-ns"}, fun() ->
        ?assertEqual(<<"leader-ns">>, pertisk_ingress_env:leader_namespace())
    end).

leader_namespace_falls_back_to_pod_namespace_test() ->
    with_env("PERTISK_K8S_LEADER_NAMESPACE", unset, fun() ->
        with_env("PERTISK_K8S_NAMESPACE", {set, "app-ns"}, fun() ->
            ?assertEqual(<<"app-ns">>, pertisk_ingress_env:leader_namespace())
        end)
    end).

holder_id_prefers_pod_name_test() ->
    with_env("PERTISK_POD_NAME", {set, "pod-1"}, fun() ->
        with_env("HOSTNAME", unset, fun() ->
            ?assertEqual(<<"pod-1">>, pertisk_ingress_env:holder_id())
        end)
    end).

holder_id_generated_when_unset_test() ->
    with_env("PERTISK_POD_NAME", unset, fun() ->
        with_env("POD_NAME", unset, fun() ->
            with_env("HOSTNAME", unset, fun() ->
                Id = pertisk_ingress_env:holder_id(),
                ?assertMatch(<<"pertisk-eproxy-", _/binary>>, Id)
            end)
        end)
    end).

env_pos_int_invalid_test() ->
    with_env("PERTISK_K8S_WATCH_BACKOFF_MS", {set, "not-a-number"}, fun() ->
        ?assertEqual(5000, pertisk_ingress_env:watch_backoff_ms())
    end),
    with_env("PERTISK_K8S_RECONCILE_INTERVAL_MS", {set, "-1"}, fun() ->
        ?assertEqual(30000, pertisk_ingress_env:reconcile_interval_ms())
    end).

k8s_tls_dir_custom_test() ->
    with_env("PERTISK_K8S_TLS_DIR", {set, "/tmp/k8s-tls"}, fun() ->
        ?assertEqual("/tmp/k8s-tls", pertisk_ingress_env:k8s_tls_dir())
    end).

controller_pod_label_selector_test() ->
    with_env("PERTISK_K8S_POD_LABEL_SELECTOR", {set, "app=test"}, fun() ->
        ?assertEqual(<<"app=test">>, pertisk_ingress_env:controller_pod_label_selector())
    end),
    with_env("PERTISK_K8S_POD_LABEL_SELECTOR", unset, fun() ->
        ?assertEqual(<<>>, pertisk_ingress_env:controller_pod_label_selector())
    end).

controller_pod_name_custom_test() ->
    with_env("PERTISK_K8S_CONTROLLER_NAME", {set, "my-controller"}, fun() ->
        ?assertEqual(<<"my-controller">>, pertisk_ingress_env:controller_pod_name())
    end).

leader_namespace_all_namespaces_fallback_test() ->
    with_env("PERTISK_K8S_NAMESPACE", unset, fun() ->
        with_env("PERTISK_K8S_LEADER_NAMESPACE", unset, fun() ->
            Ns = pertisk_ingress_env:leader_namespace(),
            ?assert(is_binary(Ns)),
            ?assert(byte_size(Ns) > 0)
        end)
    end).

publish_service_name_from_env_test() ->
    with_env("PERTISK_K8S_PUBLISH_SERVICE", {set, "ingress-lb"}, fun() ->
        ?assertEqual({ok, <<"ingress-lb">>}, pertisk_ingress_env:publish_service_name())
    end).

publish_service_name_falls_back_to_controller_test() ->
    with_env("PERTISK_K8S_PUBLISH_SERVICE", unset, fun() ->
        with_env("PERTISK_K8S_CONTROLLER_NAME", {set, "my-controller"}, fun() ->
            ?assertEqual({ok, <<"my-controller">>}, pertisk_ingress_env:publish_service_name())
        end)
    end).

publish_service_name_error_when_unset_test() ->
    with_env("PERTISK_K8S_PUBLISH_SERVICE", unset, fun() ->
        with_env("PERTISK_K8S_CONTROLLER_NAME", unset, fun() ->
            ?assertEqual(error, pertisk_ingress_env:publish_service_name())
        end)
    end).

gateway_api_enabled_defaults_false_test() ->
    with_env("PERTISK_GATEWAY_API_ENABLED", unset, fun() ->
        ?assertNot(pertisk_ingress_env:gateway_api_enabled())
    end).

gateway_api_enabled_from_env_test() ->
    with_env("PERTISK_GATEWAY_API_ENABLED", {set, "true"}, fun() ->
        ?assert(pertisk_ingress_env:gateway_api_enabled())
    end),
    with_env("PERTISK_GATEWAY_API_ENABLED", {set, "0"}, fun() ->
        ?assertNot(pertisk_ingress_env:gateway_api_enabled())
    end).
