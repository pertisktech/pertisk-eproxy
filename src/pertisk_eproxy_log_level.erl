%% @doc Runtime log level from JSON config (`log_level`) or `PERTISK_LOG_LEVEL` env.
-module(pertisk_eproxy_log_level).

-export([apply/0, configured/0, parse/1, label/1]).

-define(ENV_KEY, "PERTISK_LOG_LEVEL").
-define(DEFAULT, info).

%% @doc Apply the effective log level to Lager console and file backends.
-spec apply() -> ok.
apply() ->
    Level = configured(),
    LagerLevel = to_lager_level(Level),
    case lager:set_loglevel(lager_console_backend, LagerLevel) of
        ok ->
            ok;
        {error, _} ->
            ok
    end,
    case lager:set_loglevel(lager_file_backend, LagerLevel) of
        ok ->
            ok;
        {error, _} ->
            ok
    end,
    lager:info("Log level set to ~s", [label(Level)]),
    ok.

%% @doc Effective canonical level atom (env overrides JSON config).
-spec configured() -> atom().
configured() ->
    case os:getenv(?ENV_KEY) of
        false ->
            from_config();
        Env ->
            case parse(Env) of
                {ok, Level} ->
                    Level;
                error ->
                    from_config()
            end
    end.

%% @doc User-facing label for API / logs (`warn`, not `warning`).
-spec label(atom()) -> string().
label(Level) ->
    atom_to_list(canonical_level(Level)).

from_config() ->
    case pertisk_eproxy_config:get_config() of
        #{log_level := Level} when is_atom(Level) ->
            canonical_level(Level);
        _ ->
            ?DEFAULT
    end.

%% @doc Parse user-facing level string (debug, info, warn, error, …).
-spec parse(term()) -> {ok, atom()} | error.
parse(Level) when is_atom(Level) ->
    case normalize_atom(Level) of
        undefined -> error;
        N -> {ok, N}
    end;
parse(Level) when is_binary(Level) ->
    parse(binary_to_list(Level));
parse(Level) when is_list(Level) ->
    case normalize_string(string:lowercase(string:trim(Level))) of
        undefined -> error;
        N -> {ok, N}
    end;
parse(_) ->
    error.

%% Lager uses `warning`; config and API use `warn`.
to_lager_level(warn) -> warning;
to_lager_level(Level) -> Level.

canonical_level(warning) -> warn;
canonical_level(warn) -> warn;
canonical_level(Level) -> Level.

normalize_atom(debug) -> debug;
normalize_atom(info) -> info;
normalize_atom(notice) -> notice;
normalize_atom(warning) -> warn;
normalize_atom(warn) -> warn;
normalize_atom(error) -> error;
normalize_atom(critical) -> critical;
normalize_atom(alert) -> alert;
normalize_atom(emergency) -> emergency;
normalize_atom(_) -> undefined.

normalize_string("debug") -> debug;
normalize_string("info") -> info;
normalize_string("notice") -> notice;
normalize_string("warning") -> warn;
normalize_string("warn") -> warn;
normalize_string("error") -> error;
normalize_string("critical") -> critical;
normalize_string("alert") -> alert;
normalize_string("emergency") -> emergency;
normalize_string(_) -> undefined.
