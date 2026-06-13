%% @doc Lager formatter: one JSON object per line (stdout / file collectors).
-module(pertisk_eproxy_lager_json_formatter).

-export([format/2, format/3]).

-include_lib("lager/include/lager.hrl").

-define(SKIP_META, [severity, sev, function_arity]).

format(Msg, Config) ->
    format(Msg, Config, []).

format(Msg, _Config, _Colors) ->
    try
        [thoas:encode(build(Msg)), $\n]
    catch
        _:Reason ->
            fallback_line(Msg, Reason)
    end.

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
    {{Y, Mo, D}, {H, Mi, S}} =
        calendar:now_to_universal_time(lager_msg:timestamp(Msg)),
    Micro = element(3, lager_msg:timestamp(Msg)),
    list_to_binary(
        io_lib:format(
            "~4..0w-~2..0w-~2..0wT~2..0w:~2..0w:~2..0w.~6..0wZ",
            [Y, Mo, D, H, Mi, S, Micro]
        )
    ).

fallback_line(Msg, Reason) ->
    {Date, Time} = lager_msg:datetime(Msg),
    Level = level_bin(lager_msg:severity(Msg)),
    Text = message_bin(Msg),
    [
        <<"{\"timestamp\":\"">>,
        list_to_binary(Date),
        <<"T">>,
        list_to_binary(Time),
        <<"Z\",\"level\":\"">>,
        Level,
        <<"\",\"message\":\"">>,
        json_escape(Text),
        <<"\",\"log_format_error\":\"">>,
        json_escape(encode_value(Reason)),
        <<"\"}">>,
        $\n
    ].

json_escape(Bin) when is_binary(Bin) ->
    iolist_to_binary([escape_char(C) || <<C>> <= Bin]);
json_escape(V) ->
    json_escape(encode_value(V)).

escape_char($") -> <<"\\\"">>;
escape_char($\\) -> <<"\\\\">>;
escape_char($\n) -> <<"\\n">>;
escape_char($\r) -> <<"\\r">>;
escape_char($\t) -> <<"\\t">>;
escape_char(C) when C >= 32, C =< 126 -> <<C>>;
escape_char(C) ->
    unicode:characters_to_binary([C], utf8).

level_bin(S) when is_atom(S) ->
    atom_to_binary(S, utf8);
level_bin(S) ->
    encode_value(S).

message_bin(Msg) ->
    encode_value(lager_msg:message(Msg)).

app_name() ->
    persistent_term:get(
        {pertisk_eproxy_lager_json_formatter, app_name},
        default_app_name()
    ).

default_app_name() ->
    case application:get_env(pertisk_eproxy, log_app_name) of
        {ok, Name} when is_binary(Name) ->
            persistent_term:put({pertisk_eproxy_lager_json_formatter, app_name}, Name),
            Name;
        {ok, Name} when is_list(Name) ->
            Bin = list_to_binary(Name),
            persistent_term:put({pertisk_eproxy_lager_json_formatter, app_name}, Bin),
            Bin;
        _ ->
            Default = <<"pertisk-eproxy">>,
            persistent_term:put({pertisk_eproxy_lager_json_formatter, app_name}, Default),
            Default
    end.
