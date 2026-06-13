#!/usr/bin/env escript
%% -*- erlang -*-
%%! -noshell
-mode(compile).

main([ChunkDir, OutFile, MinStr, "gate"]) ->
    Min = list_to_integer(MinStr),
    Ebin = ebin_dir(),
    ChunkFiles = lists:sort(filelib:wildcard(filename:join(ChunkDir, "*.coverdata"))),
    case ChunkFiles of
        [] ->
            io:format(standard_error, "no chunk files in ~s~n", [ChunkDir]),
            halt(1);
        _ ->
            Best = best_per_module(ChunkFiles, Ebin),
            Modules = lists:sort(maps:keys(Best)),
            TotalCovered = lists:sum([C || {C, _} <- maps:values(Best)]),
            TotalLines = lists:sum([T || {_, T} <- maps:values(Best)]),
            TotalPct =
                if TotalLines > 0 -> 100.0 * TotalCovered / TotalLines;
                   true -> 0.0
                end,
            Below = [{M, pct(C, T)} || M <- Modules, {C, T} <- [maps:get(M, Best)], pct(C, T) < Min],
            ok = filelib:ensure_dir(OutFile),
            cover:compile_beam_directory(Ebin),
            lists:foreach(fun(F) -> cover:import(F) end, ChunkFiles),
            ok = cover:export(OutFile),
            print_summary(Modules, Best, TotalPct, Min, Below),
            case Below of
                [] when TotalPct >= Min -> halt(0);
                _ -> halt(1)
            end
    end;
main([ChunkDir, OutFile, "merge"]) ->
    Ebin = ebin_dir(),
    ChunkFiles = lists:sort(filelib:wildcard(filename:join(ChunkDir, "*.coverdata"))),
    case ChunkFiles of
        [] ->
            io:format(standard_error, "no chunk files in ~s~n", [ChunkDir]),
            halt(1);
        _ ->
            ok = filelib:ensure_dir(OutFile),
            cover:compile_beam_directory(Ebin),
            lists:foreach(fun(F) -> cover:import(F) end, ChunkFiles),
            ok = cover:export(OutFile),
            Best = best_per_module(ChunkFiles, Ebin),
            Modules = lists:sort(maps:keys(Best)),
            TotalCovered = lists:sum([C || {C, _} <- maps:values(Best)]),
            TotalLines = lists:sum([T || {_, T} <- maps:values(Best)]),
            TotalPct =
                if TotalLines > 0 -> 100.0 * TotalCovered / TotalLines;
                   true -> 0.0
                end,
            io:format("merged ~p chunks -> ~s (best-per-module total ~.2f%%)~n",
                      [length(ChunkFiles), OutFile, TotalPct]),
            print_summary(Modules, Best, TotalPct, 0, []),
            halt(0)
    end;
main(_) ->
    io:format(standard_error,
              "usage:~n"
              "  merge-cover.escript CHUNK_DIR OUT merge~n"
              "  merge-cover.escript CHUNK_DIR OUT MIN gate~n", []),
    halt(2).

ebin_dir() ->
    filename:join([os:getenv("ROOT_DIR", "."), "_build/test/lib/pertisk_eproxy/ebin"]).

best_per_module(ChunkFiles, Ebin) ->
    lists:foldl(
        fun(Chunk, Acc) ->
            cover:reset(),
            cover:compile_beam_directory(Ebin),
            cover:import(Chunk),
            {result, Modules, _} = cover:analyse(coverage, module),
            lists:foldl(
                fun({M, {C, NC}}, Inner) ->
                    T = C + NC,
                    P = pct(C, T),
                    case maps:find(M, Inner) of
                        {ok, {BestC, BestT}} ->
                            case P =< pct(BestC, BestT) of
                                true -> Inner;
                                false -> maps:put(M, {C, T}, Inner)
                            end;
                        _ ->
                            maps:put(M, {C, T}, Inner)
                    end
                end,
                Acc,
                [{M, {C, NC}} || {M, {C, NC}} <- Modules, C + NC > 0]
            )
        end,
        maps:new(),
        ChunkFiles
    ).

pct(C, T) when T > 0 -> 100.0 * C / T;
pct(_, _) -> 0.0.

print_summary(Modules, Best, TotalPct, Min, Below) ->
    io:format("~n  |--------------------------------------------|------------|~n"),
    io:format("  |                                    module  |  coverage  |~n"),
    io:format("  |--------------------------------------------|------------|~n"),
    lists:foreach(
        fun(M) ->
            {C, T} = maps:get(M, Best),
            io:format("  |  ~44s | ~8.2f%  |~n", [atom_to_list(M), pct(C, T)])
        end,
        Modules
    ),
    io:format("  |--------------------------------------------|------------|~n"),
    io:format("  |                                     total  | ~8.2f%  |~n", [TotalPct]),
    io:format("  |--------------------------------------------|------------|~n"),
    case Below of
        [] when Min > 0 ->
            io:format("===> Requiring ~p% coverage to pass. ~.2f% obtained (best-per-module)~n",
                      [Min, TotalPct]);
        [] ->
            ok;
        _ ->
            io:format("===> Modules below ~p%:~n", [Min]),
            lists:foreach(fun({M, P}) -> io:format("    ~p: ~.2f%~n", [M, P]) end, Below),
            io:format("===> Requiring ~p% coverage to pass. ~.2f% obtained (best-per-module)~n",
                      [Min, TotalPct])
    end.
