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
