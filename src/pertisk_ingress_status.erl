%% @doc In-memory ingress controller status for admin API and debugging.
-module(pertisk_ingress_status).

-export([
    init/0,
    record_success/3,
    record_error/1,
    set_leader/1,
    set_watcher_state/1,
    snapshot/0,
    live_ok/0,
    ready/0,
    ready_from_runtime/0
]).

-define(TAB, pertisk_ingress_status_tab).

init() ->
    ensure_table(),
    ok.

ensure_table() ->
    case ets:info(?TAB) of
        undefined ->
            ets:new(?TAB, [named_table, public, set, {read_concurrency, true}]),
            ets:insert(?TAB, {state, default_state()});
        _ ->
            ok
    end.

default_state() ->
    #{
        leader => false,
        watcher => disconnected,
        last_error => undefined,
        last_success_at => undefined,
        sites_count => 0,
        backends_count => 0,
        tls_secrets_count => 0
    }.

record_success(Sites, Backends, Tls) ->
    ensure_table(),
    Base = get_state(),
    Now = erlang:system_time(second),
    ets:insert(?TAB, {state, Base#{
        last_success_at => Now,
        last_error => undefined,
        watcher => connected,
        sites_count => length(Sites),
        backends_count => length(Backends),
        tls_secrets_count => tls_secrets_count(Tls)
    }}),
    ok.

record_error(Err) ->
    ensure_table(),
    Base = get_state(),
    ets:insert(?TAB, {state, Base#{last_error => format_error(Err)}}),
    ok.

set_leader(IsLeader) when is_boolean(IsLeader) ->
    ensure_table(),
    Base = get_state(),
    ets:insert(?TAB, {state, Base#{leader => IsLeader}}),
    ok.

set_watcher_state(State) when State =:= connected; State =:= disconnected; State =:= error ->
    ensure_table(),
    Base = get_state(),
    ets:insert(?TAB, {state, Base#{watcher => State}}),
    ok.

%% @doc Liveness: BEAM + management listener responding.
-spec live_ok() -> ok.
live_ok() ->
    ok.

%% @doc Readiness for K8s (Kubernetes HTTP probe).
-spec ready() -> ok | {error, binary()}.
ready() ->
    ready_from_runtime().

%% @doc True when ingress reconcile applied sites and TLS (never resets ETS).
-spec ready_from_runtime() -> ok | {error, binary()}.
ready_from_runtime() ->
    case pertisk_ingress_env:enabled() of
        false ->
            ok;
        true ->
            S = get_state(),
            case maps:get(watcher, S, disconnected) of
                error ->
                    {error, <<"ingress watcher failed (check logs and RBAC)">>};
                _ ->
                    case pertisk_eproxy_config:get_sites() of
                        [_ | _] ->
                            case ingress_tls_material_ready() of
                                true ->
                                    ok;
                                false ->
                                    {error, <<"waiting for ingress TLS material">>}
                            end;
                        [] ->
                            {error, <<"waiting for ingress reconcile (no sites yet)">>}
                    end
            end
    end.

snapshot() ->
    ensure_table(),
    S = get_state(),
    #{
        <<"enabled">> => pertisk_ingress_env:enabled(),
        <<"leader">> => maps:get(leader, S, false),
        <<"watcher">> => atom_to_binary(maps:get(watcher, S, disconnected), utf8),
        <<"last_success_at">> => maps:get(last_success_at, S, null),
        <<"last_error">> => format_snapshot_error(maps:get(last_error, S, null)),
        <<"sites_count">> => length(pertisk_eproxy_config:get_sites()),
        <<"backends_count">> => length(pertisk_eproxy_config:get_backends()),
        <<"tls_secrets_count">> => length(pertisk_ingress_tls:all_hosts()),
        <<"namespace">> => namespace_bin(),
        <<"ingress_class">> => ingress_class_bin(),
        <<"gateway_api_enabled">> => pertisk_ingress_env:gateway_api_enabled(),
        <<"gateway_class">> => gateway_class_bin()
    }.

get_state() ->
    case ets:info(?TAB) of
        undefined ->
            default_state();
        _ ->
            case ets:lookup(?TAB, state) of
                [{state, S}] -> S;
                [] -> default_state()
            end
    end.

namespace_bin() ->
    case pertisk_ingress_env:namespace() of
        all_namespaces -> <<"*">>;
        Ns when is_binary(Ns) -> Ns
    end.

ingress_class_bin() ->
    case pertisk_ingress_env:ingress_class() of
        {ok, C} -> C;
        all -> null
    end.

gateway_class_bin() ->
    case pertisk_ingress_env:gateway_api_enabled() of
        false ->
            null;
        true ->
            ingress_class_bin()
    end.

format_error(Err) when is_binary(Err) -> Err;
format_error(Err) ->
    try
        unicode:characters_to_binary(io_lib:format("~p", [Err]))
    catch
        _:_ -> <<"unknown error">>
    end.

format_snapshot_error(null) -> null;
format_snapshot_error(undefined) -> null;
format_snapshot_error(Err) -> format_error(Err).

tls_secrets_count(Tls) ->
    erlang:max(length(Tls), length(pertisk_ingress_tls:all_hosts())).

ingress_tls_material_ready() ->
    case pertisk_ingress_tls:all_hosts() of
        [_ | _] ->
            true;
        [] ->
            k8s_tls_pems_on_disk()
    end.

k8s_tls_pems_on_disk() ->
    Root = pertisk_ingress_env:k8s_tls_dir(),
    case filelib:is_dir(Root) of
        true ->
            lists:any(
                fun(NsDir) ->
                    NsPath = filename:join([Root, NsDir]),
                    lists:any(
                        fun(SecDir) ->
                            filelib:is_file(
                                filename:join([NsPath, SecDir, "tls.crt"])
                            )
                        end,
                        safe_ls(NsPath)
                    )
                end,
                safe_ls(Root)
            );
        false ->
            false
    end.

safe_ls(Dir) ->
    case file:list_dir(Dir) of
        {ok, L} -> L;
        {error, _} -> []
    end.
