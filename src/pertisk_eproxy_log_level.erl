%% @doc Runtime log level from JSON config (`log_level`) or `PERTISK_LOG_LEVEL` env.
-module(pertisk_eproxy_log_level).

-export([apply/0, configured/0, parse/1]).

-define(ENV_KEY, "PERTISK_LOG_LEVEL").
-define(DEFAULT, info).

%% @doc Apply the effective log level to Lager console and file backends.
-spec apply() -> ok.
apply() ->
    Level = configured(),
    case lager:set_loglevel(lager_console_backend, Level) of
        ok ->
            ok;
        {error, _} ->
            ok
    end,
    case lager:set_loglevel(lager_file_backend, Level) of
        ok ->
            ok;
        {error, _} ->
            ok
    end,
    lager:info("Log level set to ~s", [level_label(Level)]),
    ok.

%% @doc Effective level atom (env overrides JSON config).
-spec configured() -> lager:loglevel().
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

from_config() ->
    case pertisk_eproxy_config:get_config() of
        #{log_level := Level} when is_atom(Level) ->
            Level;
        _ ->
            ?DEFAULT
    end.

%% @doc Parse user-facing level string (debug, info, warn, warning, error, …).
-spec parse(term()) -> {ok, lager:loglevel()} | error.
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

level_label(Level) when is_atom(Level) ->
    atom_to_list(Level);
level_label(_) ->
    "unknown".

normalize_atom(debug) -> debug;
normalize_atom(info) -> info;
normalize_atom(notice) -> notice;
normalize_atom(warning) -> warning;
normalize_atom(warn) -> warning;
normalize_atom(error) -> error;
normalize_atom(critical) -> critical;
normalize_atom(alert) -> alert;
normalize_atom(emergency) -> emergency;
normalize_atom(_) -> undefined.

normalize_string("debug") -> debug;
normalize_string("info") -> info;
normalize_string("notice") -> notice;
normalize_string("warning") -> warning;
normalize_string("warn") -> warning;
normalize_string("error") -> error;
normalize_string("critical") -> critical;
normalize_string("alert") -> alert;
normalize_string("emergency") -> emergency;
normalize_string(_) -> undefined.
