%% @doc Lager formatter: one JSON object per line (stdout / file collectors).
-module(pertisk_eproxy_lager_json_formatter).

-export([format/2, format/3]).

-include_lib("lager/include/lager.hrl").

-define(SKIP_META, [severity, sev, function_arity]).

format(Msg, Config) ->
    format(Msg, Config, []).

format(Msg, _Config, _Colors) ->
    [thoas:encode(build(Msg)), $\n].

build(Msg) ->
    MetaMap = metadata_map(lager_msg:metadata(Msg)),
    maps:merge(MetaMap, #{
        <<"timestamp">> => timestamp_rfc3339(Msg),
        <<"level">> => level_bin(lager_msg:severity(Msg)),
        <<"message">> => message_bin(Msg),
        <<"app">> => app_name()
    }).

metadata_map(Metadata) ->
    maps:from_list([
        {meta_key(K), meta_value(V)}
     || {K, V} <- Metadata,
        not lists:member(K, ?SKIP_META)
    ]).

meta_key(K) when is_atom(K) -> atom_to_binary(K, utf8);
meta_key(K) when is_binary(K) -> K;
meta_key(K) -> iolist_to_binary(io_lib:format("~p", [K])).

meta_value(V) ->
    encode_value(V).

encode_value(V) when is_binary(V) ->
    V;
encode_value(V) when is_integer(V) ->
    V;
encode_value(V) when is_float(V) ->
    V;
encode_value(V) when is_boolean(V) ->
    V;
encode_value(V) when is_atom(V) ->
    atom_to_binary(V, utf8);
encode_value(V) when is_pid(V) ->
    list_to_binary(pid_to_list(V));
encode_value(V) when is_reference(V) ->
    list_to_binary(ref_to_list(V));
encode_value(V) when is_list(V) ->
    case unicode:characters_to_binary(V, utf8) of
        {Bin, _, _} when is_binary(Bin) -> Bin;
        Bin when is_binary(Bin) -> Bin;
        _ -> list_to_binary(io_lib:format("~p", [V]))
    end;
encode_value(V) when is_map(V) ->
    maps:map(fun(_, Val) -> encode_value(Val) end, V);
encode_value(V) ->
    list_to_binary(io_lib:format("~p", [V])).

timestamp_rfc3339(Msg) ->
    St =
        erlang:timestamp_to_system_time(lager_msg:timestamp(Msg), millisecond),
    list_to_binary(
        calendar:system_time_to_rfc3339(St, [{unit, millisecond}, {offset, "Z"}])
    ).

level_bin(S) when is_atom(S) ->
    atom_to_binary(S, utf8);
level_bin(S) ->
    encode_value(S).

message_bin(Msg) ->
    encode_value(lager_msg:message(Msg)).

app_name() ->
    case application:get_env(pertisk_eproxy, log_app_name) of
        {ok, Name} when is_binary(Name) -> Name;
        {ok, Name} when is_list(Name) -> list_to_binary(Name);
        _ -> <<"pertisk-eproxy">>
    end.
