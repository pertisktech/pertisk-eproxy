#!/usr/bin/env escript
%% -*- erlang -*-
%%! -noshell
-mode(compile).

main([ChunkFile]) ->
    Ebin = filename:join([os:getenv("ROOT_DIR", "."), "_build/test/lib/pertisk_eproxy/ebin"]),
    cover:compile_beam_directory(Ebin),
    ok = cover:import(ChunkFile),
    {result, Modules, _} = cover:analyse(coverage, module),
    Rows = [{M, C, T, percent(C, T)} || {M, {C, T}} <- Modules, C + T > 0],
    lists:foreach(fun({M, C, T, P}) ->
        io:format("~p ~.2f% (~p/~p)~n", [M, P, C, C + T])
    end, lists:sort(fun({_,_,_,A},{_,_,_,B}) -> A >= B end, Rows)),
    halt(0);
main(_) ->
    io:format(standard_error, "usage: ROOT_DIR=. chunk-summary.escript CHUNK~n", []),
    halt(2).

percent(C, T) when T > 0 -> 100.0 * C / T;
percent(_, _) -> 0.0.
