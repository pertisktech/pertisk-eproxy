%% @doc Structured logging helpers (emitted as JSON via {@link pertisk_eproxy_lager_json_formatter}).
-module(pertisk_eproxy_log).

-export([http/7, info/2, warning/2, error/2]).

-define(HTTP_TYPE, http).

%% @doc Proxy / admin HTTP access line with structured fields for log aggregators.
-spec http(
    Level :: binary(),
    Protocol :: binary(),
    Host :: binary(),
    Method :: binary(),
    Path :: binary(),
    Status :: integer(),
    DurationMs :: non_neg_integer()
) -> ok.
http(Level, Proto, Host, Method, Path, Status, DurationMs) ->
    Meta = [
        {type, ?HTTP_TYPE},
        {protocol, Proto},
        {host, Host},
        {method, Method},
        {path, Path},
        {status, Status},
        {duration_ms, DurationMs}
    ],
    Msg =
        iolist_to_binary(
            io_lib:format("~s ~s ~s -> ~w (~wms)", [Method, Path, Host, Status, DurationMs])
        ),
    emit(Level, Meta, Msg).

-spec info(term(), [term()]) -> ok.
info(Fmt, Args) ->
    lager:info(Fmt, Args).

-spec warning(term(), [term()]) -> ok.
warning(Fmt, Args) ->
    Msg = try iolist_to_binary(io_lib:format(Fmt, Args)) catch _:_ -> <<"(log format error)">> end,
    _ = catch pertisk_eproxy_access_log:log_system(<<"warn">>, <<"system">>, Msg),
    lager:warning(Fmt, Args).

-spec error(term(), [term()]) -> ok.
error(Fmt, Args) ->
    Msg = try iolist_to_binary(io_lib:format(Fmt, Args)) catch _:_ -> <<"(log format error)">> end,
    _ = catch pertisk_eproxy_access_log:log_system(<<"error">>, <<"error">>, Msg),
    lager:error(Fmt, Args).

emit(<<"error">>, Meta, Msg) ->
    lager:error(Meta, "~s", [Msg]);
emit(<<"warn">>, Meta, Msg) ->
    lager:warning(Meta, "~s", [Msg]);
emit(<<"warning">>, Meta, Msg) ->
    lager:warning(Meta, "~s", [Msg]);
emit(_, Meta, Msg) ->
    lager:info(Meta, "~s", [Msg]).
