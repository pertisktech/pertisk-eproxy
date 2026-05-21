%% @doc Environment and runtime flags for the Kubernetes ingress controller.
-module(pertisk_ingress_env).

-export([
    enabled/0,
    ingress_mode/0,
    namespace/0,
    ingress_class/0,
    leader_election_enabled/0,
    leader_namespace/0,
    leader_lease_name/0,
    holder_id/0,
    lease_duration_seconds/0,
    renew_interval_seconds/0,
    watch_backoff_ms/0,
    reconcile_interval_ms/0,
    k8s_tls_dir/0
]).

-define(DEFAULT_INGRESS_CLASS, <<"pertisk-eproxy">>).
-define(DEFAULT_LEASE_NAME, <<"pertisk-eproxy-leader">>).

enabled() ->
    ingress_mode() orelse env_flag(<<"PERTISK_K8S_INGRESS_ENABLED">>, false).

ingress_mode() ->
    case application:get_env(pertisk_eproxy, mode) of
        {ok, ingress} -> true;
        _ ->
            case os:getenv("PERTISK_MODE") of
                false -> false;
                V -> string:equal(V, "ingress", true)
            end
    end.

namespace() ->
    %% PERTISK_K8S_NAMESPACE set by Helm when ingress.watchNamespace is non-empty.
    %% When unset, watch all namespaces (see deploy/helm README: empty watchNamespace = all).
    case env_nonempty(<<"PERTISK_K8S_NAMESPACE">>) of
        {ok, Ns} -> Ns;
        error -> all_namespaces
    end.

ingress_class() ->
    case env_nonempty(<<"PERTISK_K8S_INGRESS_CLASS">>) of
        {ok, <<"*">>} -> all;
        {ok, C} -> {ok, C};
        error -> {ok, ?DEFAULT_INGRESS_CLASS}
    end.

leader_election_enabled() ->
    env_flag(<<"PERTISK_K8S_LEADER_ELECTION_ENABLED">>, true).

leader_namespace() ->
    case env_nonempty(<<"PERTISK_K8S_LEADER_NAMESPACE">>) of
        {ok, Ns} -> Ns;
        error ->
            case namespace() of
                all_namespaces -> default_pod_namespace();
                Ns when is_binary(Ns) -> Ns
            end
    end.

leader_lease_name() ->
    case env_nonempty(<<"PERTISK_K8S_LEADER_NAME">>) of
        {ok, N} -> N;
        error -> ?DEFAULT_LEASE_NAME
    end.

holder_id() ->
    case first_nonempty_env([<<"PERTISK_POD_NAME">>, <<"POD_NAME">>, <<"HOSTNAME">>]) of
        {ok, Id} -> Id;
        error ->
            iolist_to_binary([
                <<"pertisk-eproxy-">>,
                integer_to_binary(erlang:unique_integer([positive]))
            ])
    end.

lease_duration_seconds() ->
    env_pos_int(<<"PERTISK_K8S_LEADER_LEASE_DURATION_SECONDS">>, 15).

renew_interval_seconds() ->
    env_pos_int(<<"PERTISK_K8S_LEADER_RENEW_INTERVAL_SECONDS">>, 5).

watch_backoff_ms() ->
    env_pos_int(<<"PERTISK_K8S_WATCH_BACKOFF_MS">>, 5000).

reconcile_interval_ms() ->
    env_pos_int(<<"PERTISK_K8S_RECONCILE_INTERVAL_MS">>, 30000).

k8s_tls_dir() ->
    case os:getenv("PERTISK_K8S_TLS_DIR") of
        false -> "data/k8s-tls";
        D when is_list(D) -> D;
        _ -> "data/k8s-tls"
    end.

%% ---------------------------------------------------------------------------

env_flag(Key, Default) ->
    case os:getenv(binary_to_list(Key)) of
        false -> Default;
        V ->
            L = string:lowercase(string:trim(V)),
            lists:member(L, ["1", "true", "yes", "on"])
    end.

env_nonempty(Key) ->
    case os:getenv(binary_to_list(Key)) of
        false -> error;
        "" -> error;
        V -> {ok, list_to_binary(string:trim(V))}
    end.

first_nonempty_env(Keys) ->
    lists:foldl(
        fun
            (_, {ok, _} = Acc) -> Acc;
            (Key, _) ->
                case env_nonempty(Key) of
                    {ok, V} -> {ok, V};
                    error -> error
                end
        end,
        error,
        Keys
    ).

env_pos_int(Key, Default) ->
    case os:getenv(binary_to_list(Key)) of
        false -> Default;
        V ->
            try
                N = list_to_integer(string:trim(V)),
                if N > 0 -> N; true -> Default end
            catch
                _:_ -> Default
            end
    end.

default_pod_namespace() ->
    case file:read_file("/var/run/secrets/kubernetes.io/serviceaccount/namespace") of
        {ok, Bin} ->
            Trim = string:trim(binary_to_list(Bin)),
            case Trim of
                "" -> <<"default">>;
                Ns -> list_to_binary(Ns)
            end;
        _ ->
            <<"default">>
    end.
