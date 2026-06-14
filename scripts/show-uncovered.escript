#!/usr/bin/env escript
%%! -noshell
-mode(compile).

main([CoverFile | Mods]) ->
    Ebin = filename:join(["_build/test/lib/pertisk_eproxy/ebin"]),
    cover:compile_beam_directory(Ebin),
    cover:import(CoverFile),
    lists:foreach(fun(ModStr) -> show(list_to_atom(ModStr)) end, Mods),
    halt(0);
main(_) ->
    io:format(standard_error, "usage: show-uncovered.escript COVERFILE MOD ...~n", []),
    halt(2).

show(Mod) ->
    {ok, {Mod, {C, NC}}} = cover:analyse(Mod, coverage, module),
    Total = C + NC,
    Need = max(0, trunc(0.8 * Total) - C),
    io:format("~s: ~.2f% (~p/~p) need ~p lines for 80%~n",
              [Mod, 100.0 * C / Total, C, Total, Need]),
    halt(0).
