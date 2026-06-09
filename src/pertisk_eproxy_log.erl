%% @doc Structured logging helpers (emitted as JSON via {@link pertisk_eproxy_lager_json_formatter}).
-module(pertisk_eproxy_log).

-export([http/7, info/2, warning/2, error/2]).

-define(HTTP_TYPE, http).

%% @doc Proxy / admin HTTP access line with structured fields for log aggregators.
%% Successful (2xx/3xx) responses use debug level: at default log_level=info lager
%% drops them immediately with zero gen_event dispatch / JSON formatting / I/O.
%% The in-memory ring buffer (pertisk_eproxy_access_log) always captures entries
%% for the admin UI regardless of lager level.  4xx/5xx still emit at warn/error.
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
    emit_http(Level, Meta, Method, Path, Host, Status, DurationMs).

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

%% Use lager format strings (lazy) so the iolist is only built when the
%% message is actually written to at least one backend.
emit_http(<<"error">>, Meta, Method, Path, Host, Status, DurationMs) ->
    lager:error(Meta, "~s ~s ~s -> ~w (~wms)", [Method, Path, Host, Status, DurationMs]);
emit_http(<<"warn">>, Meta, Method, Path, Host, Status, DurationMs) ->
    lager:warning(Meta, "~s ~s ~s -> ~w (~wms)", [Method, Path, Host, Status, DurationMs]);
emit_http(<<"warning">>, Meta, Method, Path, Host, Status, DurationMs) ->
    lager:warning(Meta, "~s ~s ~s -> ~w (~wms)", [Method, Path, Host, Status, DurationMs]);
emit_http(_Level, Meta, Method, Path, Host, Status, DurationMs) ->
    %% Successful (2xx/3xx) HTTP access at debug level.
    %% At default log_level=info lager drops these immediately: no gen_event
    %% dispatch, no JSON formatter, no stderr/file I/O.
    lager:debug(Meta, "~s ~s ~s -> ~w (~wms)", [Method, Path, Host, Status, DurationMs]).
