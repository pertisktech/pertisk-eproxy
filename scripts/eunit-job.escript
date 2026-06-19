#!/usr/bin/env escript
%% Run one eunit job against precompiled test beams (no rebar3 per job).
%%
%% Parallel rebar3 eunit invocations race on _build/test/*.beam (missing_module,
%% failed .bea# renames). run-eunit.sh compiles once, then calls this script.
%%
%% Usage:
%%   eunit-job.escript --module=pertisk_foo_tests
%%   eunit-job.escript --test=pertisk_foo_tests:bar_test+baz_test
%%
%% Env:
%%   ROOT_DIR                    project root (default: parent of scripts/)
%%   PERTISK_EUNIT_COVER=1       start cover and export after the run
%%   PERTISK_EUNIT_COVER_EXPORT  base path for cover export (no .coverdata suffix)
%%   PERTISK_EUNIT_COVER_LOCAL_ONLY=1  prefer local-only cover mode (single node)
-mode(compile).

eunit_opts() ->
    Base =
        case os:getenv("EUNIT_BASE_TIMEOUT") of
            false -> 300;
            S -> list_to_integer(S)
        end,
    Scale =
        case os:getenv("EUNIT_SCALE_TIMEOUTS") of
            false -> 12.0;
            S -> list_to_float(S)
        end,
    [{scale_timeouts, Scale}, {timeout, Base}].

main(Args) ->
    ok = maybe_start_cover(),
    _ = load_code_paths(),
    Spec = parse_spec(Args),
    Result = eunit:test(Spec, eunit_opts()),
    ok = maybe_export_cover(),
    case Result of
        ok -> halt(0);
        error -> halt(1)
    end.

parse_spec(Args) ->
    case parse_spec_args(Args, undefined, undefined) of
        {module, Mod} ->
            list_to_atom(Mod);
        {test, Mod, Tests} ->
            Funs = parse_test_list(Tests),
            ModAtom = list_to_atom(Mod),
            [{test, ModAtom, Fun} || Fun <- Funs]
    end.

parse_spec_args([], module, Mod) when Mod =/= undefined ->
    {module, Mod};
parse_spec_args([], test, {Mod, Tests}) when Mod =/= undefined, Tests =/= undefined ->
    {test, Mod, Tests};
parse_spec_args([], _, _) ->
    usage_error("expected --module=Mod or --test=Mod:fun1+fun2");
parse_spec_args(["--module=" ++ Mod | Rest], _, _) ->
    parse_spec_args(Rest, module, Mod);
parse_spec_args(["--test=" ++ TestSpec | Rest], _, _) ->
    case string:split(TestSpec, ":", leading) of
        [Mod, Tests] ->
            parse_spec_args(Rest, test, {Mod, Tests});
        _ ->
            usage_error("invalid --test= value (want Mod:fun1+fun2)")
    end;
parse_spec_args([Other | _], _, _) ->
    usage_error("unknown argument: " ++ Other).

parse_test_list(Bin) when is_list(Bin) ->
    [list_to_atom(T) || T <- string:split(Bin, "+", all), T =/= ""].

load_code_paths() ->
    Root = root_dir(),
    Globs = [
        Root ++ "/_build/test/lib/*/ebin",
        Root ++ "/_build/test/lib/*/test",
        Root ++ "/_build/default/lib/*/ebin"
    ],
    Paths = lists:flatmap(fun(Glob) -> filelib:wildcard(Glob) end, Globs),
    Unique = lists:usort(Paths),
    case code:add_pathsa(Unique) of
        ok -> ok;
        {error, bad_directory} -> usage_error("failed to add code paths")
    end.

root_dir() ->
    case os:getenv("ROOT_DIR") of
        false ->
            filename:dirname(filename:dirname(escript:script_name()));
        Dir ->
            Dir
    end.

maybe_start_cover() ->
    case os:getenv("PERTISK_EUNIT_COVER") of
        "1" ->
            case cover:start() of
                {ok, _} -> ok;
                {error, {already_started, _}} -> ok
            end,
            maybe_cover_local_only(),
            case os:getenv("PERTISK_EUNIT_COVER_PRECOMPILED") of
                "1" ->
                    ok;
                _ ->
                    Ebin = filename:join(root_dir(), "_build/test/lib/pertisk_eproxy/ebin"),
                    _ = cover:compile_beam_directory(Ebin),
                    ok
            end;
        _ ->
            ok
    end.

maybe_cover_local_only() ->
    case os:getenv("PERTISK_EUNIT_COVER_LOCAL_ONLY") of
        "0" ->
            ok;
        _ ->
            case erlang:function_exported(cover, local_only, 0) of
                true ->
                    _ = catch cover:local_only(),
                    ok;
                false ->
                    ok
            end
    end.

maybe_export_cover() ->
    case os:getenv("PERTISK_EUNIT_COVER_EXPORT") of
        false ->
            ok;
        Base ->
            File = Base ++ ".coverdata",
            ok = filelib:ensure_dir(File),
            cover:export(File)
    end.

usage_error(Msg) ->
    io:format(standard_error, "eunit-job.escript: ~s~n", [Msg]),
    halt(2).
