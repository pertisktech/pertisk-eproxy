%% @doc In-memory ingress controller status for admin API and debugging.
-module(pertisk_ingress_status).

-export([
    init/0,
    record_success/3,
    record_error/1,
    set_leader/1,
    set_watcher_state/1,
    snapshot/0
]).

-define(TAB, pertisk_ingress_status_tab).

init() ->
    case ets:info(?TAB) of
        undefined ->
            ets:new(?TAB, [named_table, public, set, {read_concurrency, true}]);
        _ ->
            ok
    end,
    ets:insert(?TAB, {state, #{
        leader => false,
        watcher => disconnected,
        last_error => undefined,
        last_success_at => undefined,
        sites_count => 0,
        backends_count => 0,
        tls_secrets_count => 0
    }}),
    ok.

record_success(Sites, Backends, Tls) ->
    init(),
    Base = get_state(),
    Now = erlang:system_time(second),
    ets:insert(?TAB, {state, Base#{
        last_success_at => Now,
        last_error => undefined,
        sites_count => length(Sites),
        backends_count => length(Backends),
        tls_secrets_count => length(Tls)
    }}),
    ok.

record_error(Err) ->
    init(),
    Base = get_state(),
    ets:insert(?TAB, {state, Base#{last_error => format_error(Err)}}),
    ok.

set_leader(IsLeader) when is_boolean(IsLeader) ->
    init(),
    Base = get_state(),
    ets:insert(?TAB, {state, Base#{leader => IsLeader}}),
    ok.

set_watcher_state(State) when State =:= connected; State =:= disconnected; State =:= error ->
    init(),
    Base = get_state(),
    ets:insert(?TAB, {state, Base#{watcher => State}}),
    ok.

snapshot() ->
    init(),
    S = get_state(),
    #{
        <<"enabled">> => pertisk_ingress_env:enabled(),
        <<"leader">> => maps:get(leader, S, false),
        <<"watcher">> => atom_to_binary(maps:get(watcher, S, disconnected), utf8),
        <<"last_success_at">> => maps:get(last_success_at, S, null),
        <<"last_error">> => maps:get(last_error, S, null),
        <<"sites_count">> => maps:get(sites_count, S, 0),
        <<"backends_count">> => maps:get(backends_count, S, 0),
        <<"tls_secrets_count">> => maps:get(tls_secrets_count, S, 0),
        <<"namespace">> => namespace_bin(),
        <<"ingress_class">> => ingress_class_bin()
    }.

get_state() ->
    case ets:lookup(?TAB, state) of
        [{state, S}] -> S;
        [] -> #{}
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

format_error(Err) when is_binary(Err) -> Err;
format_error(Err) ->
    try
        unicode:characters_to_binary(io_lib:format("~p", [Err]))
    catch
        _:_ -> <<"unknown error">>
    end.
